//! The local database (SPEC.md 6.4): one SQLite file. The relay state and the local records
//! are JSON documents; the usage log is a table. No secret is ever stored here.

use std::sync::{Arc, Mutex};

use rusqlite::{params, Connection, OptionalExtension};
use sealctl_core::wire::{MachineStatus, RequestItem};
use sealctl_core::{Request, RequestKind};

use crate::cards::display_text;
use crate::codec::{encode_state, shrink_to_fit};
use crate::day::{day_end, local_month};
use crate::error::{AppError, Result};
use crate::merge::{merge_state, normalise};
use crate::model::*;
use crate::places;
use crate::prune::prune_state;

/// Usage entries kept: 13 months, at most 50,000.
pub const USAGE_MAX: i64 = 50_000;
const USAGE_MONTHS_MS: u64 = 396 * 86_400_000;
/// Pending ids are kept 10 minutes past expiry.
const PENDING_KEEP_MS: u64 = 10 * 60 * 1000;
/// However early the relay says a request expires, its id is kept as long as its signed time
/// can still be accepted after it was first seen (the body's `t` may lie up to the window ahead).
const PENDING_MIN_KEEP_MS: u64 = 2 * sealctl_core::request::TIME_WINDOW_MS;
/// The relay state blob limit, less room for the seal.
pub const STATE_LIMIT: usize = 1_048_576 - 1024;

fn now_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| d.as_millis() as u64)
}

/// A change to the relay state.
#[derive(uniffi::Enum, Debug, Clone)]
pub enum Event {
    /// A new pairing. `replaces` moves the old machine's records to it and removes it.
    /// Without `replaces`, machines with the same name show their tags.
    PairMachine {
        /// The machine.
        machine: Machine,
        /// Key of the machine it replaces.
        replaces: Option<String>,
    },
    /// Unpaired (tombstone). Its history and inventory stay.
    UnpairMachine {
        /// Key.
        key: String,
    },
    /// Nickname, 1 to 40 characters; `None` removes it.
    SetNickname {
        /// Key.
        key: String,
        /// Nickname.
        nickname: Option<String>,
    },
    /// The relay's machine list: `lastSeen` per machine.
    MachinesListed {
        /// (key, lastSeen) pairs.
        seen: Vec<MachineSeen>,
    },
    /// An answer to remember.
    RememberAnswer {
        /// The answer.
        answer: RememberedAnswer,
    },
    /// Remove an answer.
    RemoveAnswer {
        /// Agent.
        agent: String,
        /// Key name.
        key_name: String,
        /// Repository id.
        repo_id: String,
    },
    /// A new trusted place.
    AddPlace {
        /// The place.
        place: TrustedPlace,
    },
    /// Rename a place.
    RenamePlace {
        /// Id.
        id: String,
        /// Name.
        name: String,
    },
    /// Remove a place.
    RemovePlace {
        /// Id.
        id: String,
    },
    /// The words facts.
    SetWords {
        /// Facts.
        words: WordsInfo,
    },
    /// Backups.
    SetSettings {
        /// Settings.
        settings: Settings,
    },
    /// A report of a level 3 action.
    AddReport {
        /// The report.
        report: HandbackReport,
    },
    /// After a download: the merge of the local and the relay state.
    MergeRemote {
        /// The relay's state.
        remote: State,
    },
    /// Delete my relay data: every machine is gone from the phone.
    ForgetMachines,
}

/// `lastSeen` of one machine.
#[derive(uniffi::Record, Debug, Clone)]
pub struct MachineSeen {
    /// Key.
    pub key: String,
    /// Unix ms.
    pub last_seen: Option<u64>,
}

/// A change to the local records.
#[derive(uniffi::Enum, Debug, Clone)]
pub enum LocalEvent {
    /// Set a machine's day.
    SetDay {
        /// The day.
        day: DayRecord,
    },
    /// Hold a machine's sensitive requests.
    SetHold {
        /// The hold.
        hold: Hold,
    },
    /// Release a hold.
    ClearHold {
        /// Machine key.
        machine: String,
    },
    /// Keep an approved plan.
    PutPlan {
        /// The plan.
        plan: PlanApprovalRecord,
    },
    /// Keep or update a delayed action.
    PutDelayed {
        /// The action.
        action: DelayedAction,
    },
    /// Forget a delayed action.
    RemoveDelayed {
        /// Id.
        id: String,
    },
    /// Push registration.
    SetDevice {
        /// Device.
        device: DeviceInfo,
    },
    /// Onboarding progress.
    SetOnboardingStep {
        /// Step, 0 when done.
        step: u32,
    },
    /// The agent note was shown.
    AgentNoteShown,
    /// "Not this place".
    SuppressCandidate {
        /// Id.
        id: String,
    },
    /// Leave sealctl progress.
    SetLeave {
        /// Step.
        step: u32,
        /// Machines skipped.
        skipped: Vec<String>,
    },
    /// Sync bookkeeping.
    Synced {
        /// Relay revision.
        rev: u64,
        /// This was an upload.
        uploaded: bool,
    },
}

/// What one answer changed.
#[derive(uniffi::Record, Debug, Clone, PartialEq)]
pub struct AnsweredResult {
    /// The first `open` allowed for this machine since its day ended (take a place sample).
    pub first_of_day: bool,
}

/// What a report or status changed.
#[derive(uniffi::Record, Debug, Clone, PartialEq)]
pub struct ReportResult {
    /// The status `seq` stored, for the reply's `ack`.
    pub ack: Option<u64>,
    /// The hand-back report, when the machine sent one.
    pub handback: Option<HandbackReport>,
}

/// The phone's database.
#[derive(uniffi::Object)]
pub struct Store {
    conn: Mutex<Connection>,
}

fn lock(m: &Mutex<Connection>) -> Result<std::sync::MutexGuard<'_, Connection>> {
    m.lock().map_err(|_| AppError::Storage {
        msg: "poisoned".into(),
    })
}

fn read_doc<T: serde::de::DeserializeOwned + Default>(c: &Connection, key: &str) -> Result<T> {
    let json: Option<String> = c
        .query_row("SELECT json FROM doc WHERE key = ?1", params![key], |r| {
            r.get(0)
        })
        .optional()?;
    match json {
        Some(j) => Ok(serde_json::from_str(&j)?),
        None => Ok(T::default()),
    }
}

fn write_doc<T: serde::Serialize>(c: &Connection, key: &str, value: &T) -> Result<()> {
    let json = serde_json::to_string(value).map_err(|_| AppError::Decode)?;
    c.execute(
        "INSERT INTO doc(key, json) VALUES(?1, ?2) ON CONFLICT(key) DO UPDATE SET json = excluded.json",
        params![key, json],
    )?;
    Ok(())
}

/// The doc holding [`state_hash`] of the state last handed out by `state_for_upload`.
const UPLOAD_HASH: &str = "upload_hash";

/// A hash of the stored relay state, to tell whether it changed since an upload began.
fn state_hash(c: &Connection) -> Result<Option<u64>> {
    use std::hash::{Hash, Hasher};
    let json: Option<String> = c
        .query_row("SELECT json FROM doc WHERE key = 'state'", [], |r| r.get(0))
        .optional()?;
    Ok(json.map(|j| {
        let mut h = std::collections::hash_map::DefaultHasher::new();
        j.hash(&mut h);
        h.finish()
    }))
}

/// `updated` for a record changed now: later than its previous value.
fn bump(prev: u64, now: u64) -> u64 {
    now.max(prev + 1)
}

fn item_inventory(item: &RequestItem, machine: &str, now: u64, fp: &str) -> InventoryItem {
    let o = item.object.clone().unwrap_or_default();
    InventoryItem {
        purpose: item.purpose.clone(),
        id: item.id.clone(),
        words: item.words.clone().unwrap_or_else(|| fp.to_owned()),
        check: item.check.clone().unwrap_or_default(),
        machine: machine.to_owned(),
        path: o.path,
        size: o.size,
        first_use: now,
        last_use: now,
        stale: false,
        updated: now,
        deleted: false,
    }
}

fn upsert_inventory(state: &mut State, mut item: InventoryItem, now: u64) {
    match state
        .inventory
        .iter_mut()
        .find(|i| i.purpose == item.purpose && i.id == item.id && i.machine == item.machine)
    {
        Some(existing) => {
            existing.last_use = now;
            existing.stale = false;
            existing.deleted = false;
            if !item.path.is_empty() {
                existing.path = std::mem::take(&mut item.path);
            }
            if item.size > 0 {
                existing.size = item.size;
            }
            if !item.check.is_empty() {
                existing.check = item.check;
            }
            if !item.words.is_empty() {
                existing.words = item.words;
            }
            existing.updated = bump(existing.updated, now);
        }
        None => state.inventory.push(item),
    }
}

fn add_to_summary(
    state: &mut State,
    month: String,
    machine: &str,
    keys: u64,
    declined: u64,
    now: u64,
) {
    let s = match state.summaries.iter_mut().position(|s| s.month == month) {
        Some(n) => &mut state.summaries[n],
        None => {
            state.summaries.push(MonthSummary {
                month,
                ..MonthSummary::default()
            });
            state.summaries.last_mut().expect("pushed")
        }
    };
    s.keys_used += keys;
    s.requests_declined += declined;
    if keys > 0 && !s.machines.iter().any(|m| m == machine) {
        s.machines.push(machine.to_owned());
    }
    s.updated = bump(s.updated, now);
}

/// The subject a request is about, as the usage log and the card name it.
pub fn subject_label(request: &Request) -> String {
    let ctx = request.ctx().unwrap_or_default();
    if let Some(s) = ctx.subject.as_ref().filter(|s| !s.name.is_empty()) {
        return s.name.clone();
    }
    if let Some(n) = ctx.names.first() {
        return n.clone();
    }
    if let Some(u) = request
        .uses()
        .first()
        .and_then(|u| u.names.first().cloned())
    {
        return u;
    }
    if let Some(i) = request.items().first() {
        return format!("{} {}", i.purpose, i.id);
    }
    String::new()
}

#[uniffi::export]
impl Store {
    /// Opens or creates the database file.
    #[uniffi::constructor]
    pub fn open(path: String) -> Result<Arc<Self>> {
        let conn = Connection::open(path)?;
        conn.execute_batch(
            "PRAGMA journal_mode = WAL;
             CREATE TABLE IF NOT EXISTS doc (key TEXT PRIMARY KEY, json TEXT NOT NULL);
             CREATE TABLE IF NOT EXISTS usage (
               id INTEGER PRIMARY KEY AUTOINCREMENT,
               time INTEGER NOT NULL, machine TEXT NOT NULL, key TEXT NOT NULL, json TEXT NOT NULL);
             CREATE INDEX IF NOT EXISTS usage_time ON usage(time);",
        )?;
        Ok(Arc::new(Self {
            conn: Mutex::new(conn),
        }))
    }

    /// The relay state (tombstones included; lists in canonical order).
    pub fn snapshot(&self) -> Result<State> {
        let c = lock(&self.conn)?;
        read_doc(&c, "state")
    }

    /// The local records.
    pub fn local(&self) -> Result<LocalState> {
        let c = lock(&self.conn)?;
        read_doc(&c, "local")
    }

    /// Applies a change to the relay state and returns the new state.
    pub fn apply(&self, event: Event) -> Result<State> {
        let c = lock(&self.conn)?;
        let mut s: State = read_doc(&c, "state")?;
        let now = now_ms();
        apply_event(&mut s, event, now)?;
        let s = normalise(s);
        write_doc(&c, "state", &s)?;
        let mut l: LocalState = read_doc(&c, "local")?;
        l.dirty = true;
        write_doc(&c, "local", &l)?;
        Ok(s)
    }

    /// Applies a change to the local records.
    pub fn apply_local(&self, event: LocalEvent) -> Result<LocalState> {
        let c = lock(&self.conn)?;
        let mut l: LocalState = read_doc(&c, "local")?;
        let now = now_ms();
        match event {
            LocalEvent::SetDay { day } => {
                l.days.retain(|d| d.machine != day.machine);
                l.days.push(day);
            }
            LocalEvent::SetHold { hold } => {
                l.holds.retain(|h| h.machine != hold.machine);
                l.holds.push(hold);
            }
            LocalEvent::ClearHold { machine } => l.holds.retain(|h| h.machine != machine),
            LocalEvent::PutPlan { plan } => {
                l.plans
                    .retain(|p| !(p.machine == plan.machine && p.plan_hash == plan.plan_hash));
                l.plans.push(plan);
                l.plans.retain(|p| {
                    p.not_before + crate::decide::PLAN_WINDOW_MS + 7 * 86_400_000 > now
                });
            }
            LocalEvent::PutDelayed { action } => {
                l.delayed.retain(|d| d.id != action.id);
                l.delayed.push(action);
            }
            LocalEvent::RemoveDelayed { id } => l.delayed.retain(|d| d.id != id),
            LocalEvent::SetDevice { device } => l.device = device,
            LocalEvent::SetOnboardingStep { step } => l.onboarding_step = step,
            LocalEvent::AgentNoteShown => l.agent_note_shown = true,
            LocalEvent::SuppressCandidate { id } => {
                for c in l.candidates.iter_mut().filter(|c| c.id == id) {
                    c.suppressed = true;
                }
            }
            LocalEvent::SetLeave { step, skipped } => {
                l.leave_step = step;
                l.leave_skipped = skipped;
            }
            LocalEvent::Synced { rev, uploaded } => {
                l.state_rev = rev;
                if uploaded {
                    l.last_upload = now;
                    // Only when the state is still the one `state_for_upload` gave: a change
                    // made while the upload was on its way still needs one.
                    let uploading: Option<u64> = read_doc(&c, UPLOAD_HASH)?;
                    if uploading.is_some() && uploading == state_hash(&c)? {
                        l.dirty = false;
                    }
                } else {
                    l.last_download = now;
                }
            }
        }
        write_doc(&c, "local", &l)?;
        Ok(l)
    }

    /// Request ids seen in the last 10 minutes (SPEC.md 9.5). Returns `false` when this id was
    /// already answered, expired or ignored, so the request must be ignored; otherwise records
    /// it as waiting and returns `true`.
    pub fn see_request(&self, id: String, machine: String, expires: u64) -> Result<bool> {
        let c = lock(&self.conn)?;
        let mut l: LocalState = read_doc(&c, "local")?;
        let now = now_ms();
        l.pending.retain(|p| {
            p.expires
                .max(p.seen.saturating_add(PENDING_MIN_KEEP_MS))
                .saturating_add(PENDING_KEEP_MS)
                > now
        });
        if let Some(p) = l.pending.iter().find(|p| p.id == id) {
            return Ok(p.outcome == "waiting" && p.machine == machine);
        }
        l.pending.push(PendingEntry {
            id,
            machine,
            expires,
            outcome: "waiting".into(),
            seen: now,
        });
        write_doc(&c, "local", &l)?;
        Ok(true)
    }

    /// Marks a pending request `answered`, `expired` or `ignored`.
    pub fn close_request(&self, id: String, outcome: String) -> Result<()> {
        let c = lock(&self.conn)?;
        let mut l: LocalState = read_doc(&c, "local")?;
        match l.pending.iter_mut().find(|p| p.id == id) {
            Some(p) => p.outcome = outcome,
            None => l.pending.push(PendingEntry {
                id,
                outcome,
                expires: now_ms(),
                seen: now_ms(),
                ..PendingEntry::default()
            }),
        }
        write_doc(&c, "local", &l)?;
        Ok(())
    }

    /// Records an answer (SPEC.md 9.1 step 7): usage, summary, remembered answers, inventory,
    /// the day record. `outcome` is `one_tap`, `automatic`, `once`, `denied`, `confirmed`,
    /// `expired`; `allowed` says whether keys were handed out.
    pub fn answered(
        &self,
        request: Arc<Request>,
        outcome: String,
        allowed: bool,
        remember: bool,
        place_id: Option<String>,
        utc_offset_secs: i32,
    ) -> Result<AnsweredResult> {
        let now = now_ms();
        let c = lock(&self.conn)?;
        let mut s: State = read_doc(&c, "state")?;
        let mut l: LocalState = read_doc(&c, "local")?;
        let machine = request.machine();
        let ctx = request.ctx().unwrap_or_default();
        let fp = s
            .words
            .as_ref()
            .map(|w| w.fingerprint.clone())
            .unwrap_or_default();

        if let Some(p) = l.pending.iter_mut().find(|p| p.id == request.id()) {
            p.outcome = if outcome == "expired" {
                "expired"
            } else {
                "answered"
            }
            .into();
        }
        let entry = UsageEntry {
            time: now,
            machine: machine.clone(),
            key: subject_label(&request),
            agent: ctx.agent.clone(),
            repo: ctx.repo.as_ref().map(|r| r.name.clone()),
            command: Some(ctx.command.clone()).filter(|c| !c.is_empty()),
            outcome: outcome.clone(),
        };
        insert_usage(&c, &entry)?;
        let month = local_month(now, utc_offset_secs);
        let declined = u64::from(outcome == "denied");
        let keys = if allowed {
            request.items().len().max(1) as u64
        } else {
            0
        };
        add_to_summary(&mut s, month, &machine, keys, declined, now);

        if allowed {
            for u in request.uses() {
                for name in &u.names {
                    let existing = s.answers.iter_mut().find(|a| {
                        !a.deleted
                            && a.agent == u.agent
                            && a.repo_id == u.repository
                            && &a.key_name == name
                    });
                    match existing {
                        Some(a) => {
                            a.last_used = now;
                            a.updated = bump(a.updated, now);
                        }
                        None if remember => s.answers.push(RememberedAnswer {
                            agent: u.agent.clone(),
                            key_name: name.clone(),
                            repo_id: u.repository.clone(),
                            repo_name: ctx
                                .repo
                                .as_ref()
                                .filter(|r| r.id == u.repository)
                                .map(|r| r.name.clone())
                                .unwrap_or_else(|| {
                                    u.repository.rsplit('/').next().unwrap_or("").to_owned()
                                }),
                            created: now,
                            last_used: now,
                            updated: now,
                            deleted: false,
                        }),
                        None => {}
                    }
                }
            }
            for item in request.items() {
                upsert_inventory(&mut s, item_inventory(&item, &machine, now, &fp), now);
            }
        }

        let mut first_of_day = false;
        if allowed && request.kind() == RequestKind::Open {
            let active = l
                .days
                .iter()
                .find(|d| d.machine == machine)
                .is_some_and(|d| crate::decide::day_active(d, now, utc_offset_secs));
            if !active {
                first_of_day = true;
                l.days.retain(|d| d.machine != machine);
                l.days.push(DayRecord {
                    machine: machine.clone(),
                    first_approval: now,
                    place_id,
                    ends: day_end(now, utc_offset_secs),
                });
            }
        }
        l.dirty = true;
        let s = normalise(s);
        write_doc(&c, "state", &s)?;
        write_doc(&c, "local", &l)?;
        Ok(AnsweredResult { first_of_day })
    }

    /// Records a `report` request: status, uses, inventory, hand-back.
    pub fn apply_report(&self, request: Arc<Request>) -> Result<ReportResult> {
        let machine = request.machine();
        let mut result = match request.status() {
            Some(st) => self.apply_status(machine.clone(), st)?,
            None => ReportResult {
                ack: None,
                handback: None,
            },
        };
        if let Some(hb) = request.handback() {
            let now = now_ms();
            let c = lock(&self.conn)?;
            let mut s: State = read_doc(&c, "state")?;
            let name = s.machine(&machine).map(display_name).unwrap_or_default();
            let report = HandbackReport {
                id: format!("{}:{}", machine, hb.hash),
                machine: machine.clone(),
                machine_name: name,
                what: "unseal".into(),
                plan_hash: hb.hash.clone(),
                items: hb
                    .items
                    .iter()
                    .map(|i| ReportItem {
                        kind: i.kind.clone(),
                        name: i.name.clone(),
                        to: i.to.clone(),
                        state: i.state.clone(),
                    })
                    .collect(),
                run: hb.run.clone(),
                time: now,
                updated: now,
            };
            s.reports.retain(|r| r.id != report.id);
            s.reports.push(report.clone());
            let mut l: LocalState = read_doc(&c, "local")?;
            for p in l
                .plans
                .iter_mut()
                .filter(|p| p.machine == machine && p.plan_hash == hb.hash)
            {
                p.state = "done".into();
            }
            l.dirty = true;
            write_doc(&c, "state", &normalise(s))?;
            write_doc(&c, "local", &l)?;
            result.handback = Some(report);
        }
        Ok(result)
    }

    /// Records a machine status (machine channel or `report`). A `seq` already seen is ignored
    /// except for its `ack`.
    pub fn apply_status(&self, machine: String, status: MachineStatus) -> Result<ReportResult> {
        let now = now_ms();
        let c = lock(&self.conn)?;
        let mut s: State = read_doc(&c, "state")?;
        let fp = s
            .words
            .as_ref()
            .map(|w| w.fingerprint.clone())
            .unwrap_or_default();
        let Some(m) = s
            .machines
            .iter_mut()
            .find(|m| m.key == machine && !m.deleted)
        else {
            return Err(AppError::NotFound);
        };
        let seen = m.last_status.as_ref().map_or(0, |st| st.seq);
        if status.seq != 0 && status.seq <= seen {
            return Ok(ReportResult {
                ack: Some(status.seq),
                handback: None,
            });
        }
        if let Some(st) = &status.state {
            m.last_status = Some(SessionStatus {
                session: st.session.clone(),
                left: st.left,
                stop: st.stop,
                place: st.place.clone(),
                reported_at: now,
                seq: status.seq,
            });
        } else if let Some(prev) = m.last_status.as_mut() {
            prev.seq = status.seq;
        }
        m.last_seen = Some(now);
        m.updated = bump(m.updated, now);
        let month = local_month(now, 0);
        let mut uses = 0;
        // A machine resends its log until it is acknowledged, so a later status repeats the
        // entries an earlier one carried: an entry already recorded before this status is
        // skipped (two equal entries inside one status are both kept).
        let before: i64 =
            c.query_row("SELECT COALESCE(MAX(id), 0) FROM usage", [], |r| r.get(0))?;
        for e in &status.log {
            let entry = UsageEntry {
                time: if e.time > 0 { e.time } else { now },
                machine: machine.clone(),
                key: e
                    .names
                    .first()
                    .cloned()
                    .unwrap_or_else(|| e.command.clone()),
                agent: e.agent.clone(),
                repo: e
                    .repository
                    .as_ref()
                    .map(|r| r.rsplit('/').next().unwrap_or(r).to_owned()),
                command: Some(e.command.clone()).filter(|c| !c.is_empty()),
                outcome: "in_session".into(),
            };
            if e.time > 0 && usage_recorded(&c, &entry, before)? {
                continue;
            }
            insert_usage(&c, &entry)?;
            uses += e.names.len().max(1) as u64;
        }
        if uses > 0 {
            add_to_summary(&mut s, month, &machine, uses, 0, now);
        }
        for item in &status.inventory {
            upsert_inventory(&mut s, item_inventory(item, &machine, now, &fp), now);
        }
        write_doc(&c, "state", &normalise(s))?;
        let mut l: LocalState = read_doc(&c, "local")?;
        l.dirty = true;
        write_doc(&c, "local", &l)?;
        Ok(ReportResult {
            ack: Some(status.seq),
            handback: None,
        })
    }

    /// The usage log, newest first, optionally for one machine or key.
    pub fn usage(
        &self,
        machine: Option<String>,
        key: Option<String>,
        limit: u32,
    ) -> Result<Vec<UsageEntry>> {
        let c = lock(&self.conn)?;
        let mut stmt = c.prepare(
            "SELECT json FROM usage WHERE (?1 IS NULL OR machine = ?1) AND (?2 IS NULL OR key = ?2)
             ORDER BY time DESC, id DESC LIMIT ?3",
        )?;
        let rows = stmt.query_map(params![machine, key, limit], |r| r.get::<_, String>(0))?;
        let mut out = Vec::new();
        for r in rows {
            out.push(serde_json::from_str(&r?)?);
        }
        Ok(out)
    }

    /// The summary of a month (`YYYY-MM`).
    pub fn summary(&self, month: String) -> Result<MonthSummary> {
        let s = self.snapshot()?;
        Ok(s.summaries
            .into_iter()
            .find(|m| m.month == month)
            .unwrap_or(MonthSummary {
                month,
                ..MonthSummary::default()
            }))
    }

    /// Applies the lifetimes (SPEC.md 5.4 `prune`) and trims the usage log.
    pub fn prune(&self, now: u64) -> Result<State> {
        let c = lock(&self.conn)?;
        let s: State = read_doc(&c, "state")?;
        let before = s.clone();
        let s = prune_state(s, now);
        if s != before {
            write_doc(&c, "state", &s)?;
            let mut l: LocalState = read_doc(&c, "local")?;
            l.dirty = true;
            write_doc(&c, "local", &l)?;
        }
        c.execute(
            "DELETE FROM usage WHERE time < ?1",
            params![now.saturating_sub(USAGE_MONTHS_MS)],
        )?;
        c.execute(
            "DELETE FROM usage WHERE id NOT IN (SELECT id FROM usage ORDER BY time DESC LIMIT ?1)",
            params![USAGE_MAX],
        )?;
        Ok(s)
    }

    /// Adds a location sample at a first approval of the day; returns a place candidate to
    /// offer ("Trust this place?") once it has 3 days.
    pub fn place_sample(
        &self,
        sample: LocationSample,
        utc_offset_secs: i32,
    ) -> Result<Option<PlaceCandidate>> {
        let c = lock(&self.conn)?;
        let s: State = read_doc(&c, "state")?;
        let mut l: LocalState = read_doc(&c, "local")?;
        let places: Vec<TrustedPlace> = s.live_places().cloned().collect();
        let r = places::place_sample(
            std::mem::take(&mut l.candidates),
            &places,
            sample,
            utc_offset_secs,
            crate::cards::random_id(),
        );
        l.candidates = r.candidates;
        write_doc(&c, "local", &l)?;
        Ok(r.ready)
    }

    /// The encoded state to seal and upload, shortened to fit (SPEC.md 6.5).
    pub fn state_for_upload(&self) -> Result<Vec<u8>> {
        let c = lock(&self.conn)?;
        let mut s: State = read_doc(&c, "state")?;
        if shrink_to_fit(&mut s, STATE_LIMIT) {
            write_doc(&c, "state", &s)?;
            let mut l: LocalState = read_doc(&c, "local")?;
            l.backup_shortened = true;
            write_doc(&c, "local", &l)?;
        }
        write_doc(&c, UPLOAD_HASH, &state_hash(&c)?)?;
        Ok(encode_state(&s))
    }

    /// The next message `seq` for a machine.
    pub fn next_message_seq(&self, machine: String) -> Result<u64> {
        let c = lock(&self.conn)?;
        let mut l: LocalState = read_doc(&c, "local")?;
        let now = now_ms();
        let v = match l.message_seq.iter_mut().find(|m| m.machine == machine) {
            Some(m) => {
                m.value = m.value.max(now).max(m.value + 1);
                m.value
            }
            None => {
                l.message_seq.push(MachineCounter {
                    machine: machine.clone(),
                    value: now,
                });
                now
            }
        };
        write_doc(&c, "local", &l)?;
        Ok(v)
    }

    /// Erases everything (Erase sealctl from this phone).
    pub fn erase(&self) -> Result<()> {
        let c = lock(&self.conn)?;
        c.execute_batch("DELETE FROM doc; DELETE FROM usage;")?;
        Ok(())
    }
}

/// Whether a usage row equal to `e` was stored with an id up to `max_id`.
fn usage_recorded(c: &Connection, e: &UsageEntry, max_id: i64) -> Result<bool> {
    let json = serde_json::to_string(e).map_err(|_| AppError::Decode)?;
    Ok(c.query_row(
        "SELECT EXISTS(SELECT 1 FROM usage WHERE time = ?1 AND machine = ?2 AND json = ?3 AND id <= ?4)",
        params![e.time, e.machine, json, max_id],
        |r| r.get(0),
    )?)
}

fn insert_usage(c: &Connection, e: &UsageEntry) -> Result<()> {
    c.execute(
        "INSERT INTO usage(time, machine, key, json) VALUES(?1, ?2, ?3, ?4)",
        params![
            e.time,
            e.machine,
            e.key,
            serde_json::to_string(e).map_err(|_| AppError::Decode)?
        ],
    )?;
    Ok(())
}

/// The longest machine name shown; the tag after it always shows in full.
pub const NAME_DISPLAY_MAX: u32 = 64;

/// A machine's display name: nickname, or `user@host` (and the tag when shown). The name
/// comes from the machine, so it passes [`display_text`] (SPEC.md 11.7).
pub fn display_name(m: &Machine) -> String {
    if let Some(n) = m.nickname.as_ref().filter(|n| !n.is_empty()) {
        return display_text(n.clone(), NAME_DISPLAY_MAX);
    }
    let name = display_text(m.name.clone(), NAME_DISPLAY_MAX);
    if m.tag_shown {
        if let Ok(tag) = sealctl_core::machine_tag(m.key.clone()) {
            return format!("{name} #{tag}");
        }
    }
    name
}

/// [`display_name`] for the apps.
#[uniffi::export]
pub fn machine_display_name(machine: Machine) -> String {
    display_name(&machine)
}

fn apply_event(s: &mut State, event: Event, now: u64) -> Result<()> {
    match event {
        Event::PairMachine {
            mut machine,
            replaces,
        } => {
            machine.updated = bump(machine.updated, now);
            machine.deleted = false;
            if let Some(old) = replaces.filter(|o| *o != machine.key) {
                if let Some(o) = s.machines.iter_mut().find(|m| m.key == old) {
                    o.deleted = true;
                    o.updated = bump(o.updated, now);
                    if machine.nickname.is_none() {
                        machine.nickname = o.nickname.clone();
                    }
                }
                for i in s.inventory.iter_mut().filter(|i| i.machine == old) {
                    i.machine = machine.key.clone();
                    i.updated = bump(i.updated, now);
                }
            }
            s.machines.retain(|m| m.key != machine.key);
            s.machines.push(machine);
            retag(s, now);
        }
        Event::UnpairMachine { key } => {
            if let Some(m) = s.machines.iter_mut().find(|m| m.key == key) {
                m.deleted = true;
                m.updated = bump(m.updated, now);
            }
            retag(s, now);
        }
        Event::SetNickname { key, nickname } => {
            if let Some(m) = s.machines.iter_mut().find(|m| m.key == key && !m.deleted) {
                m.nickname = nickname
                    .map(|n| n.trim().chars().take(40).collect::<String>())
                    .filter(|n| !n.is_empty());
                m.updated = bump(m.updated, now);
            }
        }
        Event::MachinesListed { seen } => {
            for x in seen {
                if let Some(m) = s.machines.iter_mut().find(|m| m.key == x.key && !m.deleted) {
                    if x.last_seen.is_some() && m.last_seen < x.last_seen {
                        m.last_seen = x.last_seen;
                        m.updated = bump(m.updated, now);
                    }
                }
            }
        }
        Event::RememberAnswer { mut answer } => {
            s.answers.retain(|a| {
                !(a.agent == answer.agent
                    && a.key_name == answer.key_name
                    && a.repo_id == answer.repo_id)
            });
            answer.updated = bump(answer.updated, now);
            answer.deleted = false;
            if answer.created == 0 {
                answer.created = now;
            }
            if answer.last_used == 0 {
                answer.last_used = now;
            }
            s.answers.push(answer);
        }
        Event::RemoveAnswer {
            agent,
            key_name,
            repo_id,
        } => {
            for a in s
                .answers
                .iter_mut()
                .filter(|a| a.agent == agent && a.key_name == key_name && a.repo_id == repo_id)
            {
                a.deleted = true;
                a.updated = bump(a.updated, now);
            }
        }
        Event::AddPlace { mut place } => {
            // At most 10 places (SPEC.md 11.9): an eleventh is refused, not dropped in silence.
            if s.live_places().count() >= places::MAX_PLACES
                && !s.live_places().any(|p| p.id == place.id)
            {
                return Err(AppError::Invalid {
                    msg: format!("at most {} places", places::MAX_PLACES),
                });
            }
            place.updated = bump(place.updated, now);
            if place.created == 0 {
                place.created = now;
            }
            if place.radius <= 0.0 {
                place.radius = places::PLACE_RADIUS_M;
            }
            s.places.retain(|p| p.id != place.id);
            s.places.push(place);
        }
        Event::RenamePlace { id, name } => {
            if let Some(p) = s.places.iter_mut().find(|p| p.id == id && !p.deleted) {
                p.name = name;
                p.updated = bump(p.updated, now);
            }
        }
        Event::RemovePlace { id } => {
            if let Some(p) = s.places.iter_mut().find(|p| p.id == id) {
                p.deleted = true;
                p.updated = bump(p.updated, now);
            }
        }
        Event::SetWords { mut words } => {
            words.updated = bump(
                s.words.as_ref().map_or(0, |w| w.updated).max(words.updated),
                now,
            );
            s.words = Some(words);
        }
        Event::SetSettings { mut settings } => {
            settings.updated = bump(s.settings.updated.max(settings.updated), now);
            s.settings = settings;
        }
        Event::AddReport { mut report } => {
            report.updated = bump(report.updated, now);
            s.reports.retain(|r| r.id != report.id);
            s.reports.push(report);
        }
        Event::MergeRemote { remote } => {
            *s = merge_state(std::mem::take(s), remote);
        }
        Event::ForgetMachines => {
            for m in s.machines.iter_mut().filter(|m| !m.deleted) {
                m.deleted = true;
                m.updated = bump(m.updated, now);
            }
        }
    }
    Ok(())
}

/// Live machines that share a name show their tags; a name left alone shows none.
fn retag(s: &mut State, now: u64) {
    let names: Vec<String> = s.live_machines().map(|m| m.name.clone()).collect();
    for m in s.machines.iter_mut().filter(|m| !m.deleted) {
        let shared = names.iter().filter(|n| **n == m.name).count() >= 2;
        if m.tag_shown != shared {
            m.tag_shown = shared;
            m.updated = bump(m.updated, now);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn store() -> Arc<Store> {
        Store::open(":memory:".into()).unwrap()
    }

    fn machine(key: &str, name: &str) -> Machine {
        Machine {
            key: key.into(),
            name: name.into(),
            ..Machine::default()
        }
    }

    #[test]
    fn display_names_are_sanitised() {
        let mut m = machine(
            "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
            "dev@\u{202E}pbm\nroot",
        );
        assert_eq!(display_name(&m), "dev@\u{FFFD}pbm root");
        m.name = "n".repeat(200);
        assert_eq!(display_name(&m).chars().count(), NAME_DISPLAY_MAX as usize);
        m.tag_shown = true;
        let shown = display_name(&m);
        let tag = sealctl_core::machine_tag(m.key.clone()).unwrap();
        assert!(shown.ends_with(&format!(" #{tag}")), "{shown}");
        m.nickname = Some("desk\u{2066}top".into());
        assert_eq!(display_name(&m), "desk\u{FFFD}top");
    }

    #[test]
    fn pairing_tags_and_replace() {
        let st = store();
        st.apply(Event::PairMachine {
            machine: machine("AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA", "dev@mbp"),
            replaces: None,
        })
        .unwrap();
        let s = st
            .apply(Event::PairMachine {
                machine: machine("BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB", "dev@mbp"),
                replaces: None,
            })
            .unwrap();
        assert!(s.live_machines().all(|m| m.tag_shown));
        assert!(display_name(s.live_machines().next().unwrap()).contains(" #"));
        let s = st
            .apply(Event::UnpairMachine {
                key: "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB".into(),
            })
            .unwrap();
        assert_eq!(s.live_machines().count(), 1);
        assert!(!s.live_machines().next().unwrap().tag_shown);
        let s = st
            .apply(Event::PairMachine {
                machine: machine("CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC", "dev@mbp"),
                replaces: Some("AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA".into()),
            })
            .unwrap();
        let live: Vec<_> = s.live_machines().collect();
        assert_eq!(live.len(), 1);
        assert_eq!(live[0].key, "CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC");
        assert!(!live[0].tag_shown);
        assert!(st.local().unwrap().dirty);
    }

    #[test]
    fn replacing_a_machine_keeps_same_name_tags_right() {
        let (a, b, c, d) = (
            "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
            "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB",
            "CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC",
            "DDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDD",
        );
        let st = store();
        for k in [a, b] {
            st.apply(Event::PairMachine {
                machine: machine(k, "dev@mbp"),
                replaces: None,
            })
            .unwrap();
        }
        // A re-paired as C, same name: C and B both show their tags.
        let s = st
            .apply(Event::PairMachine {
                machine: machine(c, "dev@mbp"),
                replaces: Some(a.into()),
            })
            .unwrap();
        assert_eq!(s.live_machines().count(), 2);
        assert!(s.live_machines().all(|m| m.tag_shown));
        // C re-paired as D under a new name: B is alone with its name again.
        let s = st
            .apply(Event::PairMachine {
                machine: machine(d, "dev@studio"),
                replaces: Some(c.into()),
            })
            .unwrap();
        assert_eq!(s.live_machines().count(), 2);
        assert!(s.live_machines().all(|m| !m.tag_shown));
    }

    #[test]
    fn upload_clears_dirty_only_for_the_state_it_sent() {
        let st = store();
        st.apply(Event::ForgetMachines).unwrap();
        st.state_for_upload().unwrap();
        // A change while the upload is on its way.
        st.apply(Event::RemovePlace { id: "p".into() }).unwrap();
        st.apply(Event::AddPlace {
            place: TrustedPlace {
                id: "p".into(),
                ..TrustedPlace::default()
            },
        })
        .unwrap();
        let l = st
            .apply_local(LocalEvent::Synced {
                rev: 4,
                uploaded: true,
            })
            .unwrap();
        assert!(l.dirty && l.state_rev == 4);
        st.state_for_upload().unwrap();
        let l = st
            .apply_local(LocalEvent::Synced {
                rev: 5,
                uploaded: true,
            })
            .unwrap();
        assert!(!l.dirty);
    }

    #[test]
    fn pending_ids_outlive_an_early_expiry() {
        let st = store();
        for (id, expires) in [("r1", 0), ("r2", 1), ("r3", u64::MAX)] {
            assert!(st.see_request(id.into(), "m".into(), expires).unwrap());
            st.close_request(id.into(), "answered".into()).unwrap();
            // Seen again at once: still refused, whatever expiry the relay gave.
            assert!(!st.see_request(id.into(), "m".into(), expires).unwrap());
        }
        // Kept while a signed time first seen 15 minutes ago can still be accepted.
        let c = lock(&st.conn).unwrap();
        let mut l: LocalState = read_doc(&c, "local").unwrap();
        for p in &mut l.pending {
            p.seen = now_ms() - 15 * 60 * 1000;
        }
        write_doc(&c, "local", &l).unwrap();
        drop(c);
        assert!(!st.see_request("r2".into(), "m".into(), 1).unwrap());
    }

    #[test]
    fn resent_status_log_is_recorded_once() {
        use sealctl_core::wire::{LogEntry, MachineStatus};
        let st = store();
        let key = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";
        st.apply(Event::PairMachine {
            machine: machine(key, "dev@mbp"),
            replaces: None,
        })
        .unwrap();
        let t = now_ms() - 60_000;
        let entry = |n: u64, name: &str| LogEntry {
            time: t + n,
            command: "env".into(),
            names: vec![name.into()],
            ..LogEntry::default()
        };
        let total = |st: &Store| -> u64 {
            st.snapshot()
                .unwrap()
                .summaries
                .iter()
                .map(|s| s.keys_used)
                .sum()
        };
        // Two equal entries in one status are two uses.
        let first = vec![entry(1, "A"), entry(2, "B"), entry(2, "B")];
        st.apply_status(
            key.into(),
            MachineStatus {
                seq: 5,
                log: first.clone(),
                ..MachineStatus::default()
            },
        )
        .unwrap();
        assert_eq!(st.usage(None, None, 100).unwrap().len(), 3);
        assert_eq!(total(&st), 3);
        // The next status carries the same log, unacknowledged, and one new use.
        let mut second = first;
        second.push(entry(3, "C"));
        st.apply_status(
            key.into(),
            MachineStatus {
                seq: 6,
                log: second,
                ..MachineStatus::default()
            },
        )
        .unwrap();
        assert_eq!(st.usage(None, None, 100).unwrap().len(), 4);
        assert_eq!(total(&st), 4);
    }

    #[test]
    fn pending_ids_refuse_replays() {
        let st = store();
        let far = now_ms() + 60_000;
        assert!(st.see_request("r1".into(), "m".into(), far).unwrap());
        assert!(st.see_request("r1".into(), "m".into(), far).unwrap());
        assert!(!st.see_request("r1".into(), "other".into(), far).unwrap());
        st.close_request("r1".into(), "answered".into()).unwrap();
        assert!(!st.see_request("r1".into(), "m".into(), far).unwrap());
    }

    #[test]
    fn answers_places_words_settings() {
        let st = store();
        st.apply(Event::RememberAnswer {
            answer: RememberedAnswer {
                agent: "claude".into(),
                key_name: "K".into(),
                repo_id: "r".into(),
                ..RememberedAnswer::default()
            },
        })
        .unwrap();
        let s = st
            .apply(Event::RemoveAnswer {
                agent: "claude".into(),
                key_name: "K".into(),
                repo_id: "r".into(),
            })
            .unwrap();
        assert_eq!(s.live_answers().count(), 0);
        for n in 0..12 {
            let r = st.apply(Event::AddPlace {
                place: TrustedPlace {
                    id: format!("p{n}"),
                    name: format!("TrustedPlace {n}"),
                    ..TrustedPlace::default()
                },
            });
            // The eleventh place is refused, not dropped in silence.
            assert_eq!(r.is_err(), n >= 10, "{n}");
        }
        let s = st.snapshot().unwrap();
        assert_eq!(s.live_places().count(), 10);
        assert_eq!(s.places[0].radius, 150.0);
        let s = st
            .apply(Event::SetWords {
                words: WordsInfo {
                    fingerprint: "7Hq3".into(),
                    written_on: "2026-11-21".into(),
                    ..WordsInfo::default()
                },
            })
            .unwrap();
        assert_eq!(s.words.unwrap().fingerprint, "7Hq3");
    }

    #[test]
    fn usage_and_summary_and_prune() {
        let st = store();
        let c = lock(&st.conn).unwrap();
        for n in 0..5u64 {
            insert_usage(
                &c,
                &UsageEntry {
                    time: 1000 + n,
                    machine: if n % 2 == 0 { "a" } else { "b" }.into(),
                    key: "K".into(),
                    outcome: "one_tap".into(),
                    ..UsageEntry::default()
                },
            )
            .unwrap();
        }
        drop(c);
        let all = st.usage(None, None, 10).unwrap();
        assert_eq!(all.len(), 5);
        assert_eq!(all[0].time, 1004);
        assert_eq!(st.usage(Some("a".into()), None, 10).unwrap().len(), 3);
        st.prune(now_ms()).unwrap();
        assert!(st.usage(None, None, 10).unwrap().is_empty());
        assert_eq!(st.summary("2026-11".into()).unwrap().keys_used, 0);
    }

    #[test]
    fn local_events_and_sync() {
        let st = store();
        st.apply_local(LocalEvent::SetHold {
            hold: Hold {
                machine: "m".into(),
                until: 5,
            },
        })
        .unwrap();
        let l = st
            .apply_local(LocalEvent::ClearHold {
                machine: "m".into(),
            })
            .unwrap();
        assert!(l.holds.is_empty());
        st.apply(Event::ForgetMachines).unwrap();
        st.state_for_upload().unwrap();
        let l = st
            .apply_local(LocalEvent::Synced {
                rev: 3,
                uploaded: true,
            })
            .unwrap();
        assert!(!l.dirty && l.state_rev == 3);
        let a = st.next_message_seq("m".into()).unwrap();
        let b = st.next_message_seq("m".into()).unwrap();
        assert!(b > a);
        st.erase().unwrap();
        assert_eq!(st.local().unwrap().state_rev, 0);
    }

    #[test]
    fn merge_remote_keeps_both_sides() {
        let st = store();
        st.apply(Event::PairMachine {
            machine: machine("AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA", "a@x"),
            replaces: None,
        })
        .unwrap();
        let mut remote = State::default();
        remote.machines.push(Machine {
            updated: 1,
            ..machine("BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB", "b@x")
        });
        let s = st.apply(Event::MergeRemote { remote }).unwrap();
        assert_eq!(s.live_machines().count(), 2);
    }
}
