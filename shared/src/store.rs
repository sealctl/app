//! The local database (SPEC.md 6.4): one SQLite file. The relay state and the local records
//! are JSON documents; the usage log and the daily counts are tables. No secret is ever stored
//! here.

use std::sync::{Arc, Mutex};

use rusqlite::{params, Connection, OptionalExtension};
use sealctl_core::wire::{MachineStatus, RequestItem};
use sealctl_core::{Request, RequestKind};

use crate::cards::display_text;
use crate::clock::{Boot, ClockNow, RelayClock};
use crate::codec::{encode_state, shrink_to_fit};
use crate::day::{add_days, day_end, local_date, local_month};
use crate::error::{AppError, Result};
use crate::merge::{merge_state, normalise};
use crate::model::*;
use crate::places;
use crate::prune::prune_state;

/// Usage entries kept: 90 days, at most 50,000 (SPEC.md 6.4).
pub const USAGE_MAX: i64 = 50_000;
/// How long a usage entry is kept, and how old an entry a machine reports may be and still be
/// recorded: 90 days. The "lost or stolen machine" screen reads the last 90 days.
pub const USAGE_KEEP_MS: u64 = crate::prune::NINETY_DAYS_MS;
/// Days of daily counts kept: the Activity heatmap's 53 weeks and a margin.
pub const DAILY_KEEP_DAYS: i64 = 400;
const _: () = assert!(DAILY_KEEP_DAYS > 53 * 7);
/// The doc that says the daily counts still wait for their one backfill from the usage rows
/// stored before the counts existed.
const DAILY_BACKFILL: &str = "daily_backfill";
/// Pending ids are kept 10 minutes past the time their signed body can be accepted.
const PENDING_KEEP_MS: u64 = 10 * 60 * 1000;
/// A request's id is kept as long as its signed time can still be accepted after it was first
/// seen (the body's `t` may lie up to the window ahead). The relay's `expires` does not shorten
/// or lengthen this: a body is refused by its signed time after that anyway. A request opened
/// and answered later than it was first seen (its signed time ahead of this phone's clock) is
/// kept from its answer: `seen` moves to the time it is closed.
const PENDING_SIGNED_KEEP_MS: u64 = 2 * sealctl_core::request::TIME_WINDOW_MS;
/// The relay state blob limit, less room for the seal.
pub const STATE_LIMIT: usize = 1_048_576 - 1024;

fn now_ms() -> u64 {
    crate::clock::system_ms()
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
    /// A lock was sent for this allowance because the phone left its place (SPEC.md 11.9).
    GrantLocked {
        /// The allowance, as [`Store::grants_left`] gave it.
        grant: GrantRecord,
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
    /// Tests only: the system clock the store reads (Unix ms); 0 reads the system clock. A new
    /// store starts at [`TEST_EPOCH_MS`], so no test depends on the day it runs.
    #[cfg(test)]
    fake_now: std::sync::atomic::AtomicU64,
    /// Tests only: the since-boot clock (ms) and boot id the store reads.
    #[cfg(test)]
    fake_boot: Mutex<Boot>,
}

/// The doc holding the relay's time last learned ([`RelayClock`]).
const CLOCK: &str = "clock";

/// Tests only: where a new store's clock starts, 2026-11-20T00:00:00Z.
#[cfg(test)]
const TEST_EPOCH_MS: u64 = 1_795_132_800_000;

impl Store {
    /// The system clock.
    fn system_now(&self) -> u64 {
        #[cfg(test)]
        {
            let t = self.fake_now.load(std::sync::atomic::Ordering::SeqCst);
            if t != 0 {
                return t;
            }
        }
        now_ms()
    }

    /// The since-boot clock.
    fn boot(&self) -> Boot {
        #[cfg(test)]
        {
            if let Ok(b) = self.fake_boot.lock() {
                return b.clone();
            }
        }
        crate::clock::boot_now()
    }

    /// The corrected clock (SPEC.md 8.1), read with the connection already held.
    fn clock_in(&self, c: &Connection) -> ClockNow {
        let clock: RelayClock = read_doc(c, CLOCK).unwrap_or_default();
        clock.now(self.system_now(), &self.boot())
    }

    /// The time every change is stamped with: the corrected clock.
    fn now(&self, c: &Connection) -> u64 {
        self.clock_in(c).now
    }

    /// Tests only: sets the system clock and moves the since-boot clock by as much.
    #[cfg(test)]
    fn set_now(&self, t: u64) {
        let before = self.system_now();
        self.fake_now.store(t, std::sync::atomic::Ordering::SeqCst);
        if let Ok(mut b) = self.fake_boot.lock() {
            b.ms = b.ms.saturating_add_signed(t as i64 - before as i64);
        }
    }

    /// Tests only: sets the system clock alone, as the person holding the phone can.
    #[cfg(test)]
    fn set_system_clock(&self, t: u64) {
        self.fake_now.store(t, std::sync::atomic::Ordering::SeqCst);
    }

    /// Tests only: lets time pass on both clocks.
    #[cfg(test)]
    fn pass(&self, ms: u64) {
        let t = self.system_now() + ms;
        self.set_now(t);
    }

    /// Tests only: a reboot; the since-boot clock starts again.
    #[cfg(test)]
    fn reboot(&self, uptime: u64) {
        if let Ok(mut b) = self.fake_boot.lock() {
            *b = Boot {
                ms: uptime,
                id: format!("{}-next", b.id),
            };
        }
    }

    /// [`Store::answered`] given at `at`, recorded `now`.
    #[allow(clippy::too_many_arguments)]
    fn record_answer(
        &self,
        request: &Request,
        outcome: &str,
        allowed: bool,
        remember: bool,
        place_id: Option<String>,
        left_place: bool,
        utc_offset_secs: i32,
        at: u64,
        now: u64,
    ) -> Result<AnsweredResult> {
        let conn = lock(&self.conn)?;
        let tx = conn.unchecked_transaction()?;
        let c: &Connection = &tx;
        backfill_daily(c, utc_offset_secs)?;
        let mut s: State = read_doc(c, "state")?;
        let mut l: LocalState = read_doc(c, "local")?;
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
            p.seen = p.seen.max(now);
        }
        let entry = UsageEntry {
            time: at,
            machine: machine.clone(),
            key: subject_label(request),
            agent: ctx.agent.clone(),
            repo: ctx.repo.as_ref().map(|r| r.name.clone()),
            command: Some(ctx.command.clone()).filter(|c| !c.is_empty()),
            outcome: outcome.to_owned(),
            kind: subject_kind(request),
        };
        insert_usage(c, &entry)?;
        let month = local_month(at, utc_offset_secs);
        let declined = u64::from(outcome == "denied");
        let keys = if allowed {
            request.items().len().max(1) as u64
        } else {
            0
        };
        add_to_summary(&mut s, month, &machine, keys, declined, now);
        count_day(c, &local_date(at, utc_offset_secs), keys, declined)?;

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
                        // An answer past its 90 days (not pruned yet) is renewed only when this
                        // answer remembers; a use allowed once leaves it to expire.
                        Some(a) if remember || crate::prune::answer_live(a, at) => {
                            a.last_used = a.last_used.max(at);
                            a.updated = bump(a.updated, now);
                        }
                        Some(_) => {}
                        None if remember => {
                            let updated = bump_over(
                                s.answers
                                    .iter()
                                    .filter(|a| {
                                        a.agent == u.agent
                                            && a.repo_id == u.repository
                                            && &a.key_name == name
                                    })
                                    .map(|a| a.updated),
                                0,
                                now,
                            );
                            s.answers.push(RememberedAnswer {
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
                                created: at,
                                last_used: at,
                                updated,
                                deleted: false,
                            })
                        }
                        None => {}
                    }
                }
            }
            for item in request.items() {
                upsert_inventory(&mut s, item_inventory(&item, &machine, at, &fp), at, now);
            }
        }

        let mut first_of_day = false;
        // Only a person's answer begins a day. An answer given by itself (`automatic`, or a
        // plan's later part) needed a day that was active when it was decided; recorded after
        // that day ended (the reply took a while to post, or the extension's answer is merged
        // later), it must not begin a new one without a tap.
        if allowed && request.kind() == RequestKind::Open && answer_begins_day(outcome) {
            let active = l
                .days
                .iter()
                .find(|d| d.machine == machine)
                .is_some_and(|d| crate::decide::day_active(d, at, utc_offset_secs));
            if !active {
                first_of_day = true;
                l.days.retain(|d| d.machine != machine);
                l.days.push(DayRecord {
                    machine: machine.clone(),
                    first_approval: at,
                    place_id: place_id.clone().filter(|_| !left_place),
                    ends: day_end(at, utc_offset_secs),
                });
            }
        }
        // The machine takes its allowance from this reply's place, wherever its day began: an
        // allowance from a trusted place is locked when the phone leaves it (11.9).
        if crate::grants::sets_allowance(request.kind(), outcome, allowed) {
            crate::grants::record_grant(
                &mut l.grants,
                &machine,
                place_id,
                at,
                utc_offset_secs,
                now,
            );
        }
        l.dirty = true;
        let s = normalise(s);
        write_doc(c, "state", &s)?;
        write_doc(c, "local", &l)?;
        tx.commit()?;
        Ok(AnsweredResult { first_of_day })
    }

    /// [`Store::apply_report`] received at `at`, recorded `now`.
    fn record_report(
        &self,
        request: &Request,
        utc_offset_secs: i32,
        at: u64,
        now: u64,
    ) -> Result<ReportResult> {
        let machine = request.machine();
        let mut result = match request.status() {
            Some(st) => self.record_status(machine.clone(), st, utc_offset_secs, at, now)?,
            None => ReportResult {
                ack: None,
                handback: None,
            },
        };
        if let Some(hb) = request.handback() {
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
                time: at,
                updated: now,
            };
            let report = HandbackReport {
                updated: bump_over(
                    s.reports
                        .iter()
                        .filter(|r| r.id == report.id)
                        .map(|r| r.updated),
                    0,
                    now,
                ),
                ..report
            };
            s.reports.retain(|r| r.id != report.id);
            s.reports.push(report.clone());
            let mut l: LocalState = read_doc(&c, "local")?;
            // A cancelled approval stays cancelled, whatever report arrives after the cancel.
            for p in l.plans.iter_mut().filter(|p| {
                p.machine == machine && p.plan_hash == hb.hash && p.state != "cancelled"
            }) {
                p.state = "done".into();
            }
            l.dirty = true;
            write_doc(&c, "state", &normalise(s))?;
            write_doc(&c, "local", &l)?;
            result.handback = Some(report);
        }
        Ok(result)
    }

    /// [`Store::apply_status`] received at `at`, recorded `now`.
    fn record_status(
        &self,
        machine: String,
        status: MachineStatus,
        utc_offset_secs: i32,
        at: u64,
        now: u64,
    ) -> Result<ReportResult> {
        let conn = lock(&self.conn)?;
        let tx = conn.unchecked_transaction()?;
        let c: &Connection = &tx;
        backfill_daily(c, utc_offset_secs)?;
        let mut s: State = read_doc(c, "state")?;
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
                idle: st.idle,
                allow: st.allow,
                stop: st.stop,
                place: st.place.clone(),
                reported_at: at,
                seq: status.seq,
            });
        } else if let Some(prev) = m.last_status.as_mut() {
            prev.seq = status.seq;
        }
        m.last_seen = Some(m.last_seen.unwrap_or(0).max(at));
        m.updated = bump(m.updated, now);
        let month = local_month(at, utc_offset_secs);
        let mut uses = 0;
        // A machine resends its log until it is acknowledged, so a later status repeats the
        // entries an earlier one carried: an entry already recorded before this status is
        // skipped (two equal entries inside one status are both kept). The check needs the
        // stored row, and rows go after 90 days, so an entry older than that is neither stored
        // nor counted: whether it was counted once before or never reached the phone, it can
        // no longer be told apart from a resend (SPEC.md 6.4).
        let before: i64 =
            c.query_row("SELECT COALESCE(MAX(id), 0) FROM usage", [], |r| r.get(0))?;
        let cutoff = now.saturating_sub(USAGE_KEEP_MS);
        for e in &status.log {
            if e.time > 0 && e.time < cutoff {
                continue;
            }
            let entry = UsageEntry {
                time: if e.time > 0 { e.time } else { at },
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
                // the JSON of a resent entry must equal what an earlier version stored
                kind: None,
            };
            if e.time > 0 && usage_recorded(c, &entry, before)? {
                continue;
            }
            insert_usage(c, &entry)?;
            uses += e.names.len().max(1) as u64;
        }
        if uses > 0 {
            add_to_summary(&mut s, month, &machine, uses, 0, now);
            count_day(c, &local_date(at, utc_offset_secs), uses, 0)?;
        }
        for item in &status.inventory {
            upsert_inventory(&mut s, item_inventory(item, &machine, at, &fp), at, now);
        }
        write_doc(c, "state", &normalise(s))?;
        let mut l: LocalState = read_doc(c, "local")?;
        l.dirty = true;
        write_doc(c, "local", &l)?;
        tx.commit()?;
        Ok(ReportResult {
            ack: Some(status.seq),
            handback: None,
        })
    }
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
    now.max(prev.saturating_add(1))
}

/// `updated` for a record that replaces every copy of it held now, removed ones too: later
/// than all of them, so it wins a merge with any of them even when their times came from a
/// clock that ran ahead (another install).
fn bump_over(held: impl Iterator<Item = u64>, given: u64, now: u64) -> u64 {
    bump(held.fold(given, u64::max), now)
}

/// An inventory item used at `at`; [`upsert_inventory`] stamps `updated`.
fn item_inventory(item: &RequestItem, machine: &str, at: u64, fp: &str) -> InventoryItem {
    let o = item.object.clone().unwrap_or_default();
    InventoryItem {
        purpose: item.purpose.clone(),
        id: item.id.clone(),
        words: item.words.clone().unwrap_or_else(|| fp.to_owned()),
        check: item.check.clone().unwrap_or_default(),
        machine: machine.to_owned(),
        path: o.path,
        size: o.size,
        first_use: at,
        last_use: at,
        stale: false,
        updated: at,
        deleted: false,
    }
}

/// Records a use at `at` of an inventory item, changed `now`.
fn upsert_inventory(state: &mut State, mut item: InventoryItem, at: u64, now: u64) {
    match state
        .inventory
        .iter_mut()
        .find(|i| i.purpose == item.purpose && i.id == item.id && i.machine == item.machine)
    {
        Some(existing) => {
            existing.last_use = existing.last_use.max(at);
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
        None => state.inventory.push(InventoryItem {
            updated: now,
            ..item
        }),
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

/// What [`subject_label`] names, in the same order: the subject's kind (`secret`, `volume`,
/// `backup`, `ssh`, `machine`), `secret` for a secret name, the item's purpose for
/// `"<purpose> <id>"`, or `None` when the label is empty.
pub fn subject_kind(request: &Request) -> Option<String> {
    let ctx = request.ctx().unwrap_or_default();
    if let Some(s) = ctx.subject.as_ref().filter(|s| !s.name.is_empty()) {
        return Some(s.kind.clone()).filter(|k| !k.is_empty());
    }
    if !ctx.names.is_empty() || request.uses().first().is_some_and(|u| !u.names.is_empty()) {
        return Some("secret".into());
    }
    request.items().first().map(|i| i.purpose.clone())
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
        create_daily(&conn)?;
        Ok(Arc::new(Self {
            conn: Mutex::new(conn),
            #[cfg(test)]
            fake_now: std::sync::atomic::AtomicU64::new(TEST_EPOCH_MS),
            #[cfg(test)]
            fake_boot: Mutex::new(Boot {
                ms: 3_600_000,
                id: "boot-1".into(),
            }),
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
        let clock = self.clock_in(&c);
        apply_event(&mut s, event, clock)?;
        if clock.fresh {
            stamp_hand_added_places(&mut s, clock.now);
        }
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
        let now = self.now(&c);
        match event {
            LocalEvent::SetDay { day } => {
                l.days.retain(|d| d.machine != day.machine);
                l.days.push(day);
            }
            LocalEvent::SetHold { mut hold } => {
                // A hold only grows: a later wrong number never ends an earlier hold sooner.
                // Only ClearHold (Release now, with biometrics) ends it early. How far it
                // reaches is capped below, after every change.
                for h in l.holds.iter().filter(|h| h.machine == hold.machine) {
                    hold.until = hold.until.max(h.until);
                }
                l.holds.retain(|h| h.machine != hold.machine);
                l.holds.push(hold);
            }
            LocalEvent::ClearHold { machine } => l.holds.retain(|h| h.machine != machine),
            LocalEvent::PutPlan { mut plan } => {
                // A cancelled approval stays cancelled: a write of the same approval (same
                // request) made before the cancel was seen does not bring it back, and an
                // approval whose delayed action was already recorded as cancelled (the cancel
                // came before the approval was stored) is stored cancelled.
                let delay_cancelled = plan.delay_id.as_ref().is_some_and(|id| {
                    l.delayed
                        .iter()
                        .any(|d| &d.id == id && d.state == "cancelled")
                });
                if delay_cancelled
                    || l.plans.iter().any(|p| {
                        p.machine == plan.machine
                            && p.plan_hash == plan.plan_hash
                            && p.request_id == plan.request_id
                            && p.state == "cancelled"
                    })
                {
                    plan.state = "cancelled".into();
                }
                l.plans
                    .retain(|p| !(p.machine == plan.machine && p.plan_hash == plan.plan_hash));
                l.plans.push(plan);
                l.plans.retain(|p| {
                    p.not_before + crate::decide::PLAN_WINDOW_MS + 7 * 86_400_000 > now
                });
            }
            LocalEvent::PutDelayed { mut action } => {
                // A delayed action that ended (cancelled, finished, gone, expired) stays
                // ended: a write made from an older read (the relay's list fetched before a
                // cancel note) does not make it wait again. Only a known end (cancelled,
                // finished) replaces an unknown one (gone, expired).
                if let Some(d) = l
                    .delayed
                    .iter()
                    .find(|d| d.id == action.id && delayed_ended(&d.state))
                {
                    if !(delayed_known_end(&action.state) && !delayed_known_end(&d.state)) {
                        action.state = d.state.clone();
                        action.cancelled_by = d.cancelled_by.clone().or(action.cancelled_by);
                    }
                }
                // A write that does not know when it started (an older read) keeps the time.
                if action.started == 0 {
                    if let Some(d) = l.delayed.iter().find(|d| d.id == action.id) {
                        action.started = d.started;
                    }
                }
                // Its plan approval is cancelled with it, whichever of the two was stored first.
                if action.state == "cancelled" {
                    for p in l
                        .plans
                        .iter_mut()
                        .filter(|p| p.delay_id.as_deref() == Some(action.id.as_str()))
                    {
                        p.state = "cancelled".into();
                    }
                }
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
            LocalEvent::GrantLocked { grant } => crate::grants::grant_locked(&mut l.grants, grant),
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
        // A hold never reaches more than its hour past now: one recorded while the clock ran
        // ahead (until a year on) ends an hour after the next change once the clock is right,
        // never sooner than an hour from now.
        let cap = now.saturating_add(crate::decide::HOLD_MS);
        for h in &mut l.holds {
            h.until = h.until.min(cap);
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
        let now = self.now(&c);
        l.pending.retain(|p| {
            p.seen
                .saturating_add(PENDING_SIGNED_KEEP_MS)
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
        let now = self.clock_now()?.now;
        let c = lock(&self.conn)?;
        let mut l: LocalState = read_doc(&c, "local")?;
        match l.pending.iter_mut().find(|p| p.id == id) {
            Some(p) => {
                p.outcome = outcome;
                p.seen = p.seen.max(now);
            }
            None => l.pending.push(PendingEntry {
                id,
                outcome,
                expires: now,
                seen: now,
                ..PendingEntry::default()
            }),
        }
        write_doc(&c, "local", &l)?;
        Ok(())
    }

    /// Records an answer (SPEC.md 9.1 step 7): usage, summary, remembered answers, inventory,
    /// the day record and where the machine's allowance came from. `outcome` is `one_tap`,
    /// `automatic`, `once`, `denied`, `confirmed`, `expired`; `allowed` says whether keys were
    /// handed out. `place_id` is the trusted place the reply was decided at (it carried
    /// `trusted`); `left_place` says the phone left it while the reply was on its way, so the
    /// day does not begin there, though the allowance still came from there.
    #[allow(clippy::too_many_arguments)]
    pub fn answered(
        &self,
        request: Arc<Request>,
        outcome: String,
        allowed: bool,
        remember: bool,
        place_id: Option<String>,
        left_place: bool,
        utc_offset_secs: i32,
    ) -> Result<AnsweredResult> {
        let now = self.clock_now()?.now;
        self.record_answer(
            &request,
            &outcome,
            allowed,
            remember,
            place_id,
            left_place,
            utc_offset_secs,
            now,
            now,
        )
    }

    /// [`Store::answered`] for an answer given earlier, at `answered_at` (Unix ms): what the
    /// iOS extension answered by itself, merged from its inbox when the app next runs, which
    /// can be hours later. The use counts at the time it was given: the usage entry, its
    /// month, the answer's last use and the inventory. A time after this phone's clock counts
    /// as now.
    pub fn answered_at(
        &self,
        request: Arc<Request>,
        outcome: String,
        allowed: bool,
        place_id: Option<String>,
        utc_offset_secs: i32,
        answered_at: u64,
    ) -> Result<AnsweredResult> {
        let now = self.clock_now()?.now;
        self.record_answer(
            &request,
            &outcome,
            allowed,
            false,
            place_id,
            false,
            utc_offset_secs,
            answered_at.min(now),
            now,
        )
    }

    /// The allowances to lock now that the phone is not inside the places `left` (SPEC.md
    /// 11.9): every machine whose latest session was allowed at one of them, wherever its day
    /// began, not locked yet and not ended. Places no longer trusted lock nothing. Send each a
    /// lock, then [`LocalEvent::GrantLocked`].
    pub fn grants_left(&self, left: Vec<String>, utc_offset_secs: i32) -> Result<Vec<GrantRecord>> {
        let c = lock(&self.conn)?;
        let s: State = read_doc(&c, "state")?;
        let l: LocalState = read_doc(&c, "local")?;
        let now = self.now(&c);
        Ok(crate::grants::grants_to_lock(
            l,
            s.places,
            left,
            now,
            utc_offset_secs,
        ))
    }

    /// Records a `report` request: status, uses, inventory, hand-back. `utc_offset_secs` is
    /// the phone's UTC offset now, for the month the uses count in.
    pub fn apply_report(
        &self,
        request: Arc<Request>,
        utc_offset_secs: i32,
    ) -> Result<ReportResult> {
        let now = self.clock_now()?.now;
        self.record_report(&request, utc_offset_secs, now, now)
    }

    /// [`Store::apply_report`] for a report the iOS extension acknowledged earlier, at
    /// `received_at` (Unix ms), merged from its inbox later: the status counts as reported
    /// then (an open session's time left runs from then), and its uses in that month. A time
    /// after this phone's clock counts as now.
    pub fn apply_report_at(
        &self,
        request: Arc<Request>,
        utc_offset_secs: i32,
        received_at: u64,
    ) -> Result<ReportResult> {
        let now = self.clock_now()?.now;
        self.record_report(&request, utc_offset_secs, received_at.min(now), now)
    }

    /// Records a machine status (machine channel or `report`). A `seq` already seen is ignored
    /// except for its `ack`. The uses it reports count in this month by the phone's UTC offset
    /// now, `utc_offset_secs`, as answers do.
    pub fn apply_status(
        &self,
        machine: String,
        status: MachineStatus,
        utc_offset_secs: i32,
    ) -> Result<ReportResult> {
        let now = self.clock_now()?.now;
        self.record_status(machine, status, utc_offset_secs, now, now)
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

    /// The usage log from `since` (Unix ms) on, newest first, optionally for one machine: the
    /// days the Activity screen lists (SPEC.md 11.12).
    pub fn usage_since(&self, machine: Option<String>, since: u64) -> Result<Vec<UsageEntry>> {
        let c = lock(&self.conn)?;
        let mut stmt = c.prepare(
            "SELECT json FROM usage WHERE time >= ?1 AND (?2 IS NULL OR machine = ?2)
             ORDER BY time DESC, id DESC",
        )?;
        let rows = stmt.query_map(params![since, machine], |r| r.get::<_, String>(0))?;
        let mut out = Vec::new();
        for r in rows {
            out.push(serde_json::from_str(&r?)?);
        }
        Ok(out)
    }

    /// The daily counts from `from_day` to `to_day` (`YYYY-MM-DD`, both included), oldest
    /// first; days with nothing counted are left out (SPEC.md 11.12, the heatmap).
    /// `utc_offset_secs` is the phone's UTC offset now: it dates the one backfill from the
    /// usage rows of an older version, when that has not run yet.
    pub fn daily_counts(
        &self,
        from_day: String,
        to_day: String,
        utc_offset_secs: i32,
    ) -> Result<Vec<DailyCount>> {
        let conn = lock(&self.conn)?;
        let tx = conn.unchecked_transaction()?;
        backfill_daily(&tx, utc_offset_secs)?;
        tx.commit()?;
        let mut stmt = conn.prepare(
            "SELECT day, used, declined FROM daily WHERE day >= ?1 AND day <= ?2 ORDER BY day",
        )?;
        let rows = stmt.query_map(params![from_day, to_day], |r| {
            Ok(DailyCount {
                day: r.get(0)?,
                used: r.get(1)?,
                declined: r.get(2)?,
            })
        })?;
        Ok(rows.collect::<std::result::Result<Vec<_>, _>>()?)
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

    /// Applies the lifetimes (SPEC.md 5.4 `prune`), trims the usage log to 90 days and the
    /// daily counts to [`DAILY_KEEP_DAYS`]. `utc_offset_secs` is the phone's UTC offset now:
    /// the day the counts are kept from, and the date of the usage rows an older version
    /// stored, counted once before the first trim removes them.
    pub fn prune(&self, now: u64, utc_offset_secs: i32) -> Result<State> {
        let conn = lock(&self.conn)?;
        let tx = conn.unchecked_transaction()?;
        let c: &Connection = &tx;
        backfill_daily(c, utc_offset_secs)?;
        let s: State = read_doc(c, "state")?;
        let before = s.clone();
        let s = prune_state(s, now);
        if s != before {
            write_doc(c, "state", &s)?;
            let mut l: LocalState = read_doc(c, "local")?;
            l.dirty = true;
            write_doc(c, "local", &l)?;
        }
        c.execute(
            "DELETE FROM usage WHERE time < ?1",
            params![now.saturating_sub(USAGE_KEEP_MS)],
        )?;
        c.execute(
            "DELETE FROM usage WHERE id NOT IN (SELECT id FROM usage ORDER BY time DESC LIMIT ?1)",
            params![USAGE_MAX],
        )?;
        c.execute(
            "DELETE FROM daily WHERE day < ?1",
            params![add_days(local_date(now, utc_offset_secs), -DAILY_KEEP_DAYS)],
        )?;
        tx.commit()?;
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
        let now = self.now(&c);
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

    /// The corrected clock (SPEC.md 8.1): the relay's time carried on the since-boot clock
    /// while fresh, else the later of the system clock and the last-known relay time. Every
    /// security window is counted on it: holds, plans, the level 3 delay and places.
    pub fn clock_now(&self) -> Result<ClockNow> {
        let c = lock(&self.conn)?;
        Ok(self.clock_in(&c))
    }

    /// The relay's time, Unix ms, as the relay gave it just now: the `time` of `GET
    /// /v1/health` or of a `401 clock_skew` (seconds, times 1000).
    pub fn relay_time(&self, relay_ms: u64) -> Result<ClockNow> {
        let c = lock(&self.conn)?;
        if relay_ms == 0 {
            return Ok(self.clock_in(&c));
        }
        write_doc(&c, CLOCK, &RelayClock::learned(relay_ms, &self.boot()))?;
        let clock = self.clock_in(&c);
        // places added by hand while the clock was stale start their two hours now
        let mut s: State = read_doc(&c, "state")?;
        if clock.fresh && stamp_hand_added_places(&mut s, clock.now) {
            write_doc(&c, "state", &normalise(s))?;
            let mut l: LocalState = read_doc(&c, "local")?;
            l.dirty = true;
            write_doc(&c, "local", &l)?;
        }
        Ok(clock)
    }

    /// The relay accepted a call signed with `signed_ms` (the `Sealctl-Time` sent, in ms):
    /// its clock is within the 5-minute signature window of that. A clock that disagrees by
    /// more is stale until the relay's time is learned again.
    pub fn relay_accepted(&self, signed_ms: u64) -> Result<()> {
        let c = lock(&self.conn)?;
        let mut clock: RelayClock = read_doc(&c, CLOCK)?;
        if clock.signed_accepted(signed_ms, self.system_now(), &self.boot()) {
            write_doc(&c, CLOCK, &clock)?;
        }
        Ok(())
    }

    /// Whether a trusted place lifts the level 3 delay now ([`crate::decide::place_settled`]
    /// on the corrected clock). A place added by hand never does while the clock is stale:
    /// its two hours can't be counted on a clock the person may have set.
    pub fn place_settled_now(&self, place: TrustedPlace) -> Result<bool> {
        Ok(crate::clock::place_settled_at(place, self.clock_now()?))
    }

    /// The relay's time last learned, for the iOS extension's snapshot.
    pub fn relay_clock(&self) -> Result<RelayClock> {
        let c = lock(&self.conn)?;
        read_doc(&c, CLOCK)
    }

    /// Erases everything (Erase sealctl from this phone).
    pub fn erase(&self) -> Result<()> {
        let c = lock(&self.conn)?;
        c.execute_batch("DELETE FROM doc; DELETE FROM usage; DELETE FROM daily;")?;
        Ok(())
    }
}

/// A delayed action's state from which it never waits again.
fn delayed_ended(state: &str) -> bool {
    matches!(state, "cancelled" | "finished" | "gone" | "expired")
}

/// An end that says what happened (cancelled, and by whom; finished), rather than only that
/// the relay no longer has the action.
fn delayed_known_end(state: &str) -> bool {
    matches!(state, "cancelled" | "finished")
}

/// Whether an allowed `open` with this outcome can be the first approval of a day: only an
/// answer the person gave (SPEC.md 9.3).
fn answer_begins_day(outcome: &str) -> bool {
    matches!(outcome, "one_tap" | "once" | "confirmed")
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

/// Uses and declines counted on one local day (SPEC.md 6.4, 11.12): what the Activity heatmap
/// shows for the last year, after the usage rows behind it are gone.
#[derive(uniffi::Record, Debug, Clone, Default, PartialEq, Eq)]
pub struct DailyCount {
    /// `YYYY-MM-DD` by the phone's UTC offset when the use counted.
    pub day: String,
    /// Keys used, counted as the month's "keys used".
    pub used: u64,
    /// Deny answers, counted as the month's "requests declined".
    pub declined: u64,
}

/// [`DAILY_BACKFILL`]: the usage rows up to `upto` (their ids) were stored before the daily
/// counts existed and still wait to be counted.
#[derive(Debug, Default, serde::Serialize, serde::Deserialize)]
#[serde(default)]
struct DailyBackfill {
    upto: i64,
}

/// Creates the daily counts. A database that has usage rows but no counts yet (stored by an
/// older version) is marked to count those rows once, before a prune can remove them.
fn create_daily(c: &Connection) -> Result<()> {
    let tx = c.unchecked_transaction()?;
    let exists: bool = tx.query_row(
        "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'daily')",
        [],
        |r| r.get(0),
    )?;
    if !exists {
        tx.execute_batch(
            "CREATE TABLE daily (
               day TEXT PRIMARY KEY, used INTEGER NOT NULL DEFAULT 0,
               declined INTEGER NOT NULL DEFAULT 0);",
        )?;
        let upto: i64 = tx.query_row("SELECT COALESCE(MAX(id), 0) FROM usage", [], |r| r.get(0))?;
        if upto > 0 {
            write_doc(&tx, DAILY_BACKFILL, &DailyBackfill { upto })?;
        }
    }
    tx.commit()?;
    Ok(())
}

/// Counts, once, the usage rows an older version stored before the daily counts existed
/// (SPEC.md 6.4). A row holds one entry, not how many keys its request handed out, and the
/// time of the entry, not when a machine's report of it reached the phone: each row counts one
/// use (or one decline, for `denied`; `expired` counts neither) on its own local day by
/// `utc_offset_secs`. Rows stored after the counts existed (ids above the mark) were counted
/// when they were stored.
fn backfill_daily(c: &Connection, utc_offset_secs: i32) -> Result<()> {
    let mark: DailyBackfill = read_doc(c, DAILY_BACKFILL)?;
    if mark.upto <= 0 {
        return Ok(());
    }
    let mut days: std::collections::BTreeMap<String, (u64, u64)> = Default::default();
    {
        let mut stmt = c.prepare("SELECT time, json FROM usage WHERE id <= ?1")?;
        let rows = stmt.query_map(params![mark.upto], |r| {
            Ok((r.get::<_, u64>(0)?, r.get::<_, String>(1)?))
        })?;
        for row in rows {
            let (time, json) = row?;
            let Ok(e) = serde_json::from_str::<UsageEntry>(&json) else {
                continue;
            };
            let d = days.entry(local_date(time, utc_offset_secs)).or_default();
            match e.outcome.as_str() {
                "denied" => d.1 += 1,
                "expired" => {}
                _ => d.0 += 1,
            }
        }
    }
    for (day, (used, declined)) in days {
        count_day(c, &day, used, declined)?;
    }
    c.execute("DELETE FROM doc WHERE key = ?1", params![DAILY_BACKFILL])?;
    Ok(())
}

/// Adds uses and declines to a local day's counts.
fn count_day(c: &Connection, day: &str, used: u64, declined: u64) -> Result<()> {
    if used == 0 && declined == 0 {
        return Ok(());
    }
    c.execute(
        "INSERT INTO daily(day, used, declined) VALUES(?1, ?2, ?3)
         ON CONFLICT(day) DO UPDATE SET used = used + excluded.used,
           declined = declined + excluded.declined",
        params![day, used, declined],
    )?;
    Ok(())
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

/// Opens a request that was already answered, against the time it was answered
/// (`answered_at`, Unix ms) instead of the clock now: for recording what the iOS extension
/// answered by itself (its inbox), which the app may merge hours later, after the signed time
/// has left the 10-minute window. Everything else is checked as `open_request` checks it. Only
/// for [`Store::answered_at`] and [`Store::apply_report_at`]; a request to answer is opened
/// with `open_request`.
#[uniffi::export]
pub fn open_answered_request(
    keys: Arc<sealctl_core::PhoneKeys>,
    relay_machine_key: String,
    id: String,
    sealed: String,
    answered_at: u64,
) -> std::result::Result<Arc<Request>, sealctl_core::CoreError> {
    sealctl_core::request::open_request_at(&keys, &relay_machine_key, &id, &sealed, answered_at)
        .map(Arc::new)
}

/// Stamps `created` on the live places added by hand that have none (added while the clock was
/// stale), so their two hours start on a fresh clock (SPEC.md 8.1, 9.6). Returns whether any was.
fn stamp_hand_added_places(s: &mut State, now: u64) -> bool {
    let mut changed = false;
    for p in s
        .places
        .iter_mut()
        .filter(|p| p.manual && !p.deleted && p.created == 0)
    {
        p.created = now;
        p.updated = bump(p.updated, now);
        changed = true;
    }
    changed
}

fn apply_event(s: &mut State, event: Event, clock: ClockNow) -> Result<()> {
    let now = clock.now;
    match event {
        Event::PairMachine {
            mut machine,
            replaces,
        } => {
            // Newer than any copy of this key already held, a kept tombstone too, so the
            // pairing wins a merge with it even if that tombstone's time came from a clock
            // that ran ahead.
            let held = s
                .machines
                .iter()
                .find(|m| m.key == machine.key)
                .map_or(0, |m| m.updated);
            machine.updated = bump(machine.updated.max(held), now);
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
            let same = |a: &RememberedAnswer| {
                a.agent == answer.agent
                    && a.key_name == answer.key_name
                    && a.repo_id == answer.repo_id
            };
            answer.updated = bump_over(
                s.answers.iter().filter(|a| same(a)).map(|a| a.updated),
                answer.updated,
                now,
            );
            s.answers.retain(|a| !same(a));
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
            place.updated = bump_over(
                s.places
                    .iter()
                    .filter(|p| p.id == place.id)
                    .map(|p| p.updated),
                place.updated,
                now,
            );
            // A place added by hand starts its two hours only on a fresh clock: a stale one can
            // be days behind, and the place would be settled as soon as the clock is fresh.
            // Until then `created` stays 0 (see stamp_hand_added_places).
            if place.created == 0 && (clock.fresh || !place.manual) {
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
            report.updated = bump_over(
                s.reports
                    .iter()
                    .filter(|r| r.id == report.id)
                    .map(|r| r.updated),
                report.updated,
                now,
            );
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

    /// 2026-11-21T00:00:00Z.
    const MIDNIGHT: u64 = 1_795_219_200_000;
    const H: u64 = 3_600_000;
    const MIN: u64 = 60_000;

    /// A request of `why` signed by `machine` at `t`, opened at `t`.
    fn request_at(
        machine: &sealctl_core::machine::MachineKeys,
        why: &str,
        t: u64,
        uses: Vec<sealctl_core::wire::AgentUse>,
    ) -> Arc<Request> {
        request_with(machine, why, t, |b| b.uses = uses)
    }

    thread_local! {
        /// This test phone's keys.
        static KEYS: Arc<sealctl_core::PhoneKeys> = Arc::new(sealctl_core::PhoneKeys::from_root(
            &sealctl_core::Root::from_words(&sealctl_core::Words::generate().unwrap()),
        ));
    }

    /// A request of `why` signed by `machine` at `t`, as the relay carries it: (id, sealed).
    fn sealed_with(
        machine: &sealctl_core::machine::MachineKeys,
        why: &str,
        t: u64,
        f: impl FnOnce(&mut sealctl_core::wire::RequestBody),
    ) -> (String, String) {
        use sealctl_core::request::{new_request_id, seal_request};
        let keys = KEYS.with(Arc::clone);
        let phone = sealctl_core::PhonePublic::from_b64u(&keys.public_id(), &keys.box_public_key())
            .unwrap();
        let id = new_request_id().unwrap();
        let mut body = sealctl_core::wire::RequestBody {
            v: 1,
            t,
            why: why.into(),
            ..Default::default()
        };
        f(&mut body);
        let sealed = seal_request(machine, &phone, &id, body).unwrap();
        (id, sealed.sealed)
    }

    /// [`request_at`] with the body set up by `f`.
    fn request_with(
        machine: &sealctl_core::machine::MachineKeys,
        why: &str,
        t: u64,
        f: impl FnOnce(&mut sealctl_core::wire::RequestBody),
    ) -> Arc<Request> {
        let (id, sealed) = sealed_with(machine, why, t, f);
        open_answered_request(KEYS.with(Arc::clone), machine.id(), id, sealed, t).unwrap()
    }

    fn paired(st: &Store) -> sealctl_core::machine::MachineKeys {
        let m = sealctl_core::machine::MachineKeys::generate().unwrap();
        st.apply(Event::PairMachine {
            machine: machine(&m.id(), "dev@mbp"),
            replaces: None,
        })
        .unwrap();
        m
    }

    fn day_of(st: &Store, key: &str) -> Option<DayRecord> {
        st.local()
            .unwrap()
            .days
            .into_iter()
            .find(|d| d.machine == key)
    }

    #[test]
    fn an_answer_given_by_itself_never_begins_a_day() {
        let st = store();
        let m = paired(&st);
        // The day begins with a tap at 13:00 at the desk; it ends at 02:00.
        st.set_now(MIDNIGHT + 13 * H);
        let r = request_at(&m, "open", MIDNIGHT + 13 * H, Vec::new());
        let first = st
            .answered(
                r,
                "one_tap".into(),
                true,
                false,
                Some("desk".into()),
                false,
                0,
            )
            .unwrap();
        assert!(first.first_of_day);
        let day = day_of(&st, &m.id()).unwrap();
        assert_eq!(day.ends, MIDNIGHT + 26 * H);
        // An open decided by itself at 01:59:59 is recorded once its reply was posted, after
        // 02:00: the answer was the old day's, and begins no new one.
        let r = request_at(&m, "open", MIDNIGHT + 26 * H - 1000, Vec::new());
        st.set_now(MIDNIGHT + 26 * H + 2000);
        let late = st
            .answered(
                r,
                "automatic".into(),
                true,
                false,
                Some("desk".into()),
                false,
                0,
            )
            .unwrap();
        assert!(!late.first_of_day);
        assert_eq!(day_of(&st, &m.id()), Some(day));
        // So the next morning's first open at the desk still asks.
        let morning = MIDNIGHT + 33 * H;
        let d = day_of(&st, &m.id()).unwrap();
        assert!(!crate::decide::day_active(&d, morning, 0));
        // The same for a later part of an approved plan, answered without asking.
        let r = request_at(&m, "open", MIDNIGHT + 30 * H, Vec::new());
        st.set_now(MIDNIGHT + 30 * H);
        let plan = st
            .answered(
                r,
                "in_session".into(),
                true,
                false,
                Some("desk".into()),
                false,
                0,
            )
            .unwrap();
        assert!(!plan.first_of_day);
        // A tap after 02:00 begins the day.
        let r = request_at(&m, "open", morning, Vec::new());
        st.set_now(morning);
        let tap = st
            .answered(r, "once".into(), true, false, Some("desk".into()), false, 0)
            .unwrap();
        assert!(tap.first_of_day);
        assert_eq!(day_of(&st, &m.id()).unwrap().first_approval, morning);
    }

    fn trust(st: &Store, id: &str) {
        st.apply(Event::AddPlace {
            place: TrustedPlace {
                id: id.into(),
                name: id.into(),
                lat: 50.45,
                lon: 30.52,
                radius: 150.0,
                created: MIDNIGHT,
                manual: true,
                ..TrustedPlace::default()
            },
        })
        .unwrap();
    }

    fn keys_of(g: Vec<GrantRecord>) -> Vec<String> {
        let mut k: Vec<String> = g.into_iter().map(|g| g.machine).collect();
        k.sort();
        k
    }

    /// The owner's morning: the Mac's day began at 07:13 before any place existed; at 07:26
    /// Home was trusted and the Mac was allowed again there, so its reply carried `trusted`
    /// (4 h). Leaving Home must lock it, though its day did not begin there (SPEC.md 11.9).
    #[test]
    fn leaving_a_place_locks_a_machine_allowed_there_whose_day_began_elsewhere() {
        let st = store();
        let mac = paired(&st);
        let pc = paired(&st);
        let laptop = paired(&st);
        let t = |h: u64, m: u64| MIDNIGHT + h * H + m * MIN;
        // 07:13, no place: the Mac's day begins with no place.
        st.set_now(t(7, 13));
        let r = request_at(&mac, "open", t(7, 13), Vec::new());
        assert!(
            st.answered(r, "one_tap".into(), true, false, None, false, 0)
                .unwrap()
                .first_of_day
        );
        assert_eq!(day_of(&st, &mac.id()).unwrap().place_id, None);
        // The PC's and the laptop's days begin with no place too.
        let r = request_at(&pc, "open", t(7, 15), Vec::new());
        st.answered(r, "one_tap".into(), true, false, None, false, 0)
            .unwrap();
        // 07:26: "Trust where I am now".
        trust(&st, "home");
        // The Mac locked by itself and is allowed again at Home; the laptop too.
        st.set_now(t(9, 0));
        let r = request_at(&mac, "open", t(9, 0), Vec::new());
        assert!(
            !st.answered(
                r,
                "one_tap".into(),
                true,
                false,
                Some("home".into()),
                false,
                0
            )
            .unwrap()
            .first_of_day
        );
        assert_eq!(day_of(&st, &mac.id()).unwrap().place_id, None);
        let r = request_at(&laptop, "open", t(9, 5), Vec::new());
        st.answered(
            r,
            "automatic".into(),
            true,
            false,
            Some("home".into()),
            false,
            0,
        )
        .unwrap();
        // The PC's latest session was allowed elsewhere ("Allow once" at Home opens none).
        let r = request_at(&pc, "open", t(9, 10), Vec::new());
        st.answered(r, "once".into(), true, false, Some("home".into()), false, 0)
            .unwrap();
        // A walk: leaving Home locks the Mac and the laptop, not the PC.
        st.set_now(t(10, 0));
        let left = st.grants_left(vec!["home".into()], 0).unwrap();
        assert_eq!(keys_of(left.clone()), {
            let mut k = vec![mac.id(), laptop.id()];
            k.sort();
            k
        });
        // Once the locks are sent, leaving again sends none.
        for g in left {
            st.apply_local(LocalEvent::GrantLocked { grant: g })
                .unwrap();
        }
        assert!(st.grants_left(vec!["home".into()], 0).unwrap().is_empty());
        // Opened again at Home: the next exit locks it again.
        let r = request_at(&mac, "open", t(11, 0), Vec::new());
        st.set_now(t(11, 0));
        st.answered(
            r,
            "one_tap".into(),
            true,
            false,
            Some("home".into()),
            false,
            0,
        )
        .unwrap();
        assert_eq!(
            keys_of(st.grants_left(vec!["home".into()], 0).unwrap()),
            vec![mac.id()]
        );
        // Opened again elsewhere: Home no longer locks it.
        let r = request_at(&mac, "open", t(12, 0), Vec::new());
        st.set_now(t(12, 0));
        st.answered(r, "one_tap".into(), true, false, None, false, 0)
            .unwrap();
        assert!(st.grants_left(vec!["home".into()], 0).unwrap().is_empty());
    }

    /// An allow decided at the place and posted after the phone left it: the day does not
    /// begin there, but the machine's allowance came from there, so the place still locks it.
    #[test]
    fn an_answer_on_its_way_when_the_phone_left_still_counts_for_the_place() {
        let st = store();
        let m = paired(&st);
        trust(&st, "home");
        st.set_now(MIDNIGHT + 9 * H);
        let r = request_at(&m, "open", MIDNIGHT + 9 * H, Vec::new());
        st.answered(
            r,
            "one_tap".into(),
            true,
            false,
            Some("home".into()),
            true,
            0,
        )
        .unwrap();
        assert_eq!(day_of(&st, &m.id()).unwrap().place_id, None);
        assert_eq!(
            keys_of(st.grants_left(vec!["home".into()], 0).unwrap()),
            vec![m.id()]
        );
    }

    /// Removing a place: machines opened there stay Open until their allowance ends (11.9).
    #[test]
    fn a_removed_place_locks_nothing() {
        let st = store();
        let m = paired(&st);
        trust(&st, "home");
        st.set_now(MIDNIGHT + 9 * H);
        let r = request_at(&m, "open", MIDNIGHT + 9 * H, Vec::new());
        st.answered(
            r,
            "one_tap".into(),
            true,
            false,
            Some("home".into()),
            false,
            0,
        )
        .unwrap();
        st.apply(Event::RemovePlace { id: "home".into() }).unwrap();
        assert!(st.grants_left(vec!["home".into()], 0).unwrap().is_empty());
    }

    #[test]
    fn an_answer_the_extension_gave_counts_when_its_inbox_is_merged_late() {
        use sealctl_core::wire::AgentUse;
        let st = store();
        let m = paired(&st);
        let t0 = MIDNIGHT + 9 * H;
        st.set_now(t0);
        st.apply(Event::RememberAnswer {
            answer: RememberedAnswer {
                agent: "claude".into(),
                key_name: "K".into(),
                repo_id: "r".into(),
                ..RememberedAnswer::default()
            },
        })
        .unwrap();
        // 89 days on, the extension answers the agent's use by itself; the app runs again
        // five hours later and merges the inbox.
        let used = t0 + 89 * 24 * H;
        let (id, sealed) = sealed_with(&m, "agent", used, |b| {
            b.uses = vec![AgentUse {
                agent: "claude".into(),
                repository: "r".into(),
                names: vec!["K".into()],
            }];
        });
        let merged = used + 5 * H;
        st.set_now(merged);
        // Opened against the clock now, the signed time is long outside its window.
        assert!(matches!(
            KEYS.with(|k| sealctl_core::request::open_request_at(k, &m.id(), &id, &sealed, merged)),
            Err(sealctl_core::CoreError::Expired)
        ));
        let req = open_answered_request(KEYS.with(Arc::clone), m.id(), id, sealed, used).unwrap();
        let r = st
            .answered_at(req, "automatic".into(), true, Some("desk".into()), 0, used)
            .unwrap();
        assert!(!r.first_of_day);
        // The use renews the answer, and counts when it was made.
        let a = st.snapshot().unwrap().answers[0].clone();
        assert_eq!(a.last_used, used);
        let u = st.usage(None, None, 10).unwrap();
        assert_eq!((u[0].time, u[0].outcome.as_str()), (used, "automatic"));
        assert_eq!(st.summary(local_month(used, 0)).unwrap().keys_used, 1);
        // So it still answers by itself past the 90 days from its first remembering.
        assert!(crate::prune::answer_live(&a, t0 + 100 * 24 * H));
        assert!(!st.prune(t0 + 100 * 24 * H, 0).unwrap().answers[0].deleted);
        // An answer time after the phone's clock counts as now.
        let r = request_at(&m, "open", merged + H, Vec::new());
        st.answered_at(r, "automatic".into(), true, None, 0, merged + H)
            .unwrap();
        assert_eq!(st.usage(None, None, 1).unwrap()[0].time, merged);
    }

    #[test]
    fn a_report_the_extension_acknowledged_counts_from_when_it_came() {
        use sealctl_core::wire::{LogEntry, SessionState};
        let st = store();
        let m = paired(&st);
        let came = MIDNIGHT + 9 * H;
        // An open session with 10 minutes left, reported at 09:00 and merged at 11:00.
        let r = request_with(&m, "report", came, |b| {
            b.seq = Some(7);
            b.state = Some(SessionState {
                session: "open".into(),
                left: Some(600),
                ..SessionState::default()
            });
            b.log = vec![LogEntry {
                command: "env".into(),
                names: vec!["A".into()],
                ..LogEntry::default()
            }];
            b.handback = Some(sealctl_core::wire::Handback {
                hash: "h".into(),
                ..Default::default()
            });
        });
        st.set_now(came - H);
        for (hash, state) in [("h", "approved"), ("h2", "cancelled")] {
            st.apply_local(LocalEvent::PutPlan {
                plan: PlanApprovalRecord {
                    machine: m.id(),
                    request_id: hash.into(),
                    plan_hash: hash.into(),
                    not_before: came - H,
                    state: state.into(),
                    ..PlanApprovalRecord::default()
                },
            })
            .unwrap();
        }
        st.set_now(came + 2 * H);
        let res = st.apply_report_at(r, 0, came).unwrap();
        assert_eq!(res.ack, Some(7));
        assert_eq!(res.handback.unwrap().time, came);
        let mach = st.snapshot().unwrap().machine(&m.id()).cloned().unwrap();
        // The session's time left runs from 09:00: it is not shown open at 11:00.
        let status = mach.last_status.unwrap();
        assert_eq!(status.reported_at, came);
        assert_eq!(mach.last_seen, Some(came));
        assert_eq!(st.usage(None, None, 1).unwrap()[0].time, came);
        // With a status in the same report, the hand-back still marks its plan done.
        let l = st.local().unwrap();
        let state = |h: &str| {
            l.plans
                .iter()
                .find(|p| p.plan_hash == h)
                .unwrap()
                .state
                .clone()
        };
        assert_eq!(
            (state("h"), state("h2")),
            ("done".into(), "cancelled".into())
        );
        // The same hand-back for a cancelled plan, with a status, leaves it cancelled.
        let r = request_with(&m, "report", came + MIN, |b| {
            b.seq = Some(8);
            b.state = Some(SessionState {
                session: "locked".into(),
                ..SessionState::default()
            });
            b.handback = Some(sealctl_core::wire::Handback {
                hash: "h2".into(),
                ..Default::default()
            });
        });
        assert_eq!(st.apply_report(r, 0).unwrap().ack, Some(8));
        let l = st.local().unwrap();
        assert_eq!(
            l.plans.iter().find(|p| p.plan_hash == "h2").unwrap().state,
            "cancelled"
        );
    }

    #[test]
    fn a_late_answer_keeps_its_id_as_long_as_its_body_can_be_opened() {
        let w = sealctl_core::request::TIME_WINDOW_MS;
        let st = store();
        let t0 = MIDNIGHT + 9 * H;
        // Seen at 09:00 but not opened then (signed 25 minutes ahead of this phone's clock),
        // opened and answered at 09:25.
        st.set_now(t0);
        assert!(st.see_request("r1".into(), "m".into(), 0).unwrap());
        st.set_now(t0 + 25 * MIN);
        st.close_request("r1".into(), "answered".into()).unwrap();
        let m = paired(&st);
        let req = request_at(&m, "open", t0 + 25 * MIN, Vec::new());
        st.set_now(t0);
        assert!(st.see_request(req.id(), req.machine(), 0).unwrap());
        st.set_now(t0 + 25 * MIN);
        st.answered(req.clone(), "one_tap".into(), true, false, None, false, 0)
            .unwrap();
        // Its body can be opened until 09:45: until then (and the 10 minutes after) the id is
        // refused, although it was first seen more than 30 minutes ago.
        st.set_now(t0 + 25 * MIN + 2 * w + PENDING_KEEP_MS - 1);
        assert!(!st.see_request("r1".into(), "m".into(), 0).unwrap());
        assert!(!st.see_request(req.id(), req.machine(), 0).unwrap());
        st.set_now(t0 + 25 * MIN + 2 * w + PENDING_KEEP_MS);
        assert!(st.see_request("r1".into(), "m".into(), 0).unwrap());
    }

    #[test]
    fn a_use_allowed_once_does_not_revive_an_answer_past_its_lifetime() {
        use sealctl_core::wire::AgentUse;
        let st = store();
        let m = paired(&st);
        let t0 = MIDNIGHT + 9 * H;
        st.set_now(t0);
        st.apply(Event::RememberAnswer {
            answer: RememberedAnswer {
                agent: "claude".into(),
                key_name: "K".into(),
                repo_id: "r".into(),
                ..RememberedAnswer::default()
            },
        })
        .unwrap();
        let uses = || {
            vec![AgentUse {
                agent: "claude".into(),
                repository: "r".into(),
                names: vec!["K".into()],
            }]
        };
        // 91 days later, before any prune: the agent asks again and is allowed once.
        let later = t0 + 91 * 24 * H;
        st.set_now(later);
        let r = request_at(&m, "agent", later, uses());
        st.answered(r, "once".into(), true, false, None, false, 0)
            .unwrap();
        let a = st.snapshot().unwrap().answers[0].clone();
        assert_eq!(a.last_used, t0);
        assert!(st.prune(later, 0).unwrap().answers[0].deleted);
        // Allowed and remembered: the answer is kept again from now.
        let r = request_at(&m, "agent", later, uses());
        st.answered(r, "one_tap".into(), true, true, None, false, 0)
            .unwrap();
        let s = st.snapshot().unwrap();
        assert_eq!(s.live_answers().count(), 1);
        assert_eq!(s.live_answers().next().unwrap().last_used, later);
    }

    #[test]
    fn re_adding_beats_a_removal_from_a_clock_ahead() {
        use sealctl_core::wire::AgentUse;
        let st = store();
        let t0 = MIDNIGHT + 9 * H;
        let answer = || RememberedAnswer {
            agent: "claude".into(),
            key_name: "K".into(),
            repo_id: "r".into(),
            ..RememberedAnswer::default()
        };
        st.set_now(t0);
        st.apply(Event::RememberAnswer { answer: answer() })
            .unwrap();
        // Removed on an install whose clock runs a day ahead; this phone merged that.
        st.set_now(t0 + 24 * H);
        let removed = st
            .apply(Event::RemoveAnswer {
                agent: "claude".into(),
                key_name: "K".into(),
                repo_id: "r".into(),
            })
            .unwrap();
        // Remembered again here an hour later: it must win a merge with that removal.
        st.set_now(t0 + H);
        let s = st
            .apply(Event::RememberAnswer { answer: answer() })
            .unwrap();
        let merged = crate::merge::merge_state(removed.clone(), s);
        assert_eq!(merged.live_answers().count(), 1);
        // The same when the agent's first use is allowed and remembered.
        let st = store();
        st.apply(Event::MergeRemote {
            remote: removed.clone(),
        })
        .unwrap();
        st.set_now(t0 + H);
        let m = paired(&st);
        let uses = vec![AgentUse {
            agent: "claude".into(),
            repository: "r".into(),
            names: vec!["K".into()],
        }];
        let r = request_at(&m, "open", t0 + H, uses);
        st.answered(r, "one_tap".into(), true, true, None, false, 0)
            .unwrap();
        let merged = crate::merge::merge_state(removed, st.snapshot().unwrap());
        assert_eq!(merged.live_answers().count(), 1);
    }

    #[test]
    fn a_prune_wins_over_copies_stamped_by_a_clock_ahead() {
        let t0 = MIDNIGHT + 9 * H;
        let ahead = t0 + 24 * H;
        let held = State {
            answers: vec![RememberedAnswer {
                agent: "claude".into(),
                key_name: "K".into(),
                repo_id: "r".into(),
                created: t0 - 200 * 24 * H,
                last_used: t0 - 91 * 24 * H,
                updated: ahead,
                ..RememberedAnswer::default()
            }],
            ..State::default()
        };
        let pruned = crate::prune::prune_state(held.clone(), t0);
        assert!(pruned.answers[0].deleted);
        let merged = crate::merge::merge_state(pruned, held);
        assert!(merged.answers[0].deleted);
    }

    #[test]
    fn a_later_wrong_number_never_shortens_a_hold() {
        let st = store();
        let t0 = MIDNIGHT + 9 * H;
        st.set_now(t0);
        let hold = |until| LocalEvent::SetHold {
            hold: Hold {
                machine: "m".into(),
                until,
            },
        };
        st.apply_local(hold(t0 + H)).unwrap();
        // A second wrong number recorded with an earlier end (its time read before the first
        // was stored, or the clock was set back): the hold keeps the later end.
        let l = st.apply_local(hold(t0 + H - 5 * MIN)).unwrap();
        assert_eq!(l.holds.len(), 1);
        assert_eq!(l.holds[0].until, t0 + H);
        // A wrong number half an hour on holds an hour from then.
        st.set_now(t0 + 30 * MIN);
        let l = st.apply_local(hold(t0 + H + 30 * MIN)).unwrap();
        assert_eq!(l.holds[0].until, t0 + H + 30 * MIN);
        // Only a release ends it early.
        let l = st
            .apply_local(LocalEvent::ClearHold {
                machine: "m".into(),
            })
            .unwrap();
        assert!(l.holds.is_empty());
    }

    #[test]
    fn a_hold_recorded_while_the_clock_ran_ahead_ends_an_hour_after_it_is_right() {
        let st = store();
        let t0 = MIDNIGHT + 9 * H;
        let year = 365 * 24 * H;
        // A wrong number while the phone's clock reads a year ahead.
        st.set_now(t0 + year);
        let l = st
            .apply_local(LocalEvent::SetHold {
                hold: Hold {
                    machine: "m".into(),
                    until: t0 + year + H,
                },
            })
            .unwrap();
        assert_eq!(l.holds[0].until, t0 + year + H);
        // The clock is put right; the next change of the local records caps the hold at an
        // hour from now: still held for that hour, not for a year.
        st.set_now(t0 + 10 * MIN);
        let l = st
            .apply_local(LocalEvent::Synced {
                rev: 1,
                uploaded: false,
            })
            .unwrap();
        assert_eq!(l.holds[0].until, t0 + 10 * MIN + H);
        // A clock set back: the hold still lasts its full hour from when it is capped.
        st.set_now(t0 - 2 * H);
        let l = st.apply_local(LocalEvent::AgentNoteShown).unwrap();
        assert_eq!(l.holds[0].until, t0 - H);
    }

    #[test]
    fn a_cancelled_delay_cancels_its_plan_whichever_is_stored_first() {
        let st = store();
        let t0 = MIDNIGHT + 9 * H;
        st.set_now(t0);
        let action = |id: &str, state: &str, by: Option<&str>| LocalEvent::PutDelayed {
            action: DelayedAction {
                id: id.into(),
                what: "unseal_all".into(),
                machine: Some("m".into()),
                release_at: t0 + 2 * H,
                expires: t0 + 2 * H + 15 * MIN,
                state: state.into(),
                cancelled_by: by.map(Into::into),
                ..Default::default()
            },
        };
        let plan = |id: &str, hash: &str| LocalEvent::PutPlan {
            plan: PlanApprovalRecord {
                machine: "m".into(),
                request_id: id.into(),
                plan_hash: hash.into(),
                not_before: t0 + 2 * H,
                state: "delayed".into(),
                delay_id: Some(id.into()),
                ..PlanApprovalRecord::default()
            },
        };
        // The machine cancels while the reply is posted: the cancel is recorded before the
        // approval is stored.
        st.apply_local(action("d1", "cancelled", Some("m")))
            .unwrap();
        st.apply_local(action("d1", "waiting", None)).unwrap();
        let l = st.apply_local(plan("d1", "h1")).unwrap();
        assert_eq!(l.plans[0].state, "cancelled");
        // The other order: the approval first, then the cancel.
        st.apply_local(plan("d2", "h2")).unwrap();
        let l = st
            .apply_local(action("d2", "cancelled", Some("m")))
            .unwrap();
        let p = l.plans.iter().find(|p| p.request_id == "d2").unwrap();
        assert_eq!(p.state, "cancelled");
    }

    #[test]
    fn a_known_end_replaces_gone_but_nothing_makes_an_end_wait() {
        let st = store();
        let t0 = MIDNIGHT + 9 * H;
        st.set_now(t0);
        let action = |state: &str, by: Option<&str>| LocalEvent::PutDelayed {
            action: DelayedAction {
                id: "d1".into(),
                what: "unseal_all".into(),
                machine: Some("m".into()),
                release_at: t0 + 2 * H,
                expires: t0 + 2 * H + 15 * MIN,
                state: state.into(),
                cancelled_by: by.map(Into::into),
                ..Default::default()
            },
        };
        // The relay's list no longer has it (gone), then the cancel note says who cancelled.
        st.apply_local(action("gone", None)).unwrap();
        let l = st.apply_local(action("cancelled", Some("m"))).unwrap();
        assert_eq!(l.delayed[0].state, "cancelled");
        assert_eq!(l.delayed[0].cancelled_by.as_deref(), Some("m"));
        for (state, by) in [("waiting", None), ("gone", None), ("finished", None)] {
            let l = st.apply_local(action(state, by)).unwrap();
            assert_eq!(l.delayed[0].state, "cancelled");
            assert_eq!(l.delayed[0].cancelled_by.as_deref(), Some("m"));
        }
        // Expired, then finished.
        st.apply_local(LocalEvent::RemoveDelayed { id: "d1".into() })
            .unwrap();
        st.apply_local(action("expired", None)).unwrap();
        assert_eq!(
            st.apply_local(action("waiting", None)).unwrap().delayed[0].state,
            "expired"
        );
        assert_eq!(
            st.apply_local(action("finished", None)).unwrap().delayed[0].state,
            "finished"
        );
    }

    #[test]
    fn a_finished_action_stays_finished() {
        // A place confirmed with `finish`, then a list read before it (released) and a late
        // `404 gone`, in either order (SPEC.md 11.9, 11.23).
        let st = store();
        let t0 = MIDNIGHT + 9 * H;
        st.set_now(t0);
        let action = |state: &str| LocalEvent::PutDelayed {
            action: DelayedAction {
                id: "p1".into(),
                what: "place".into(),
                release_at: t0 + 2 * H,
                expires: t0 + 3 * H,
                state: state.into(),
                ..Default::default()
            },
        };
        st.apply_local(action("released")).unwrap();
        st.apply_local(action("finished")).unwrap();
        for state in ["released", "gone", "waiting", "expired", "cancelled"] {
            let l = st.apply_local(action(state)).unwrap();
            assert_eq!(l.delayed[0].state, "finished", "after {state}");
        }
    }

    #[test]
    fn a_write_without_a_start_time_keeps_the_stored_one() {
        let st = store();
        let t0 = MIDNIGHT + 9 * H;
        st.set_now(t0);
        let action = |state: &str, started: u64| LocalEvent::PutDelayed {
            action: DelayedAction {
                id: "d1".into(),
                what: "words".into(),
                release_at: t0 + 2 * H,
                expires: t0 + 3 * H,
                state: state.into(),
                started,
                ..Default::default()
            },
        };
        st.apply_local(action("waiting", t0)).unwrap();
        let l = st.apply_local(action("released", 0)).unwrap();
        assert_eq!(
            (l.delayed[0].state.as_str(), l.delayed[0].started),
            ("released", t0)
        );
    }

    #[test]
    fn a_cancel_is_not_undone_by_an_older_write() {
        let st = store();
        let t0 = MIDNIGHT + 9 * H;
        st.set_now(t0);
        let action = |state: &str, by: Option<&str>| LocalEvent::PutDelayed {
            action: DelayedAction {
                id: "d1".into(),
                what: "unseal_all".into(),
                machine: Some("m".into()),
                release_at: t0 + 2 * H,
                expires: t0 + 2 * H + 15 * MIN,
                state: state.into(),
                cancelled_by: by.map(Into::into),
                ..Default::default()
            },
        };
        st.apply_local(action("waiting", None)).unwrap();
        // The cancel note arrives while the relay's list, read just before it, is on its way.
        st.apply_local(action("cancelled", Some("m"))).unwrap();
        let l = st.apply_local(action("waiting", None)).unwrap();
        assert_eq!(l.delayed[0].state, "cancelled");
        assert_eq!(l.delayed[0].cancelled_by.as_deref(), Some("m"));

        let plan = |request: &str, state: &str| LocalEvent::PutPlan {
            plan: PlanApprovalRecord {
                machine: "m".into(),
                request_id: request.into(),
                plan_hash: "h".into(),
                not_before: t0 + 2 * H,
                state: state.into(),
                delay_id: Some(request.into()),
                ..PlanApprovalRecord::default()
            },
        };
        st.apply_local(plan("d1", "delayed")).unwrap();
        st.apply_local(plan("d1", "cancelled")).unwrap();
        // A write of the same approval made before the cancel was seen.
        let l = st.apply_local(plan("d1", "delayed")).unwrap();
        assert_eq!(l.plans.len(), 1);
        assert_eq!(l.plans[0].state, "cancelled");
        // The same plan approved again by a new request is a new approval.
        let l = st.apply_local(plan("d2", "delayed")).unwrap();
        assert_eq!(
            (l.plans[0].request_id.as_str(), l.plans[0].state.as_str()),
            ("d2", "delayed")
        );
    }

    #[test]
    fn uses_reported_by_a_machine_count_in_the_phone_s_month() {
        use sealctl_core::wire::{LogEntry, MachineStatus};
        let st = store();
        let m = paired(&st);
        // 23:30 on 2026-11-30 in UTC-5, 04:30 on 2026-12-01 UTC.
        let t = 1_796_099_400_000;
        assert_eq!(crate::day::local_date(t, -5 * 3600), "2026-11-30");
        assert_eq!(crate::day::local_date(t, 0), "2026-12-01");
        st.set_now(t);
        let r = request_at(&m, "open", t, Vec::new());
        st.answered(r, "one_tap".into(), true, false, None, false, -5 * 3600)
            .unwrap();
        st.apply_status(
            m.id(),
            MachineStatus {
                seq: 1,
                log: vec![LogEntry {
                    time: t,
                    command: "env".into(),
                    names: vec!["A".into(), "B".into()],
                    ..LogEntry::default()
                }],
                ..MachineStatus::default()
            },
            -5 * 3600,
        )
        .unwrap();
        assert_eq!(st.summary("2026-11".into()).unwrap().keys_used, 3);
        assert_eq!(st.summary("2026-12".into()).unwrap().keys_used, 0);
    }

    #[test]
    fn a_status_keeps_the_idle_time_and_the_allowance() {
        use sealctl_core::wire::{MachineStatus, SessionState};
        let st = store();
        let m = paired(&st);
        let t = 1_796_099_400_000;
        st.set_now(t);
        let status = |seq: u64, idle: Option<u64>, allow: Option<u64>| MachineStatus {
            seq,
            state: Some(SessionState {
                session: "open".into(),
                left: Some(13_680),
                idle,
                allow,
                ..SessionState::default()
            }),
            ..MachineStatus::default()
        };
        st.apply_status(m.id(), status(1, Some(720), Some(14_400)), 0)
            .unwrap();
        let last = |st: &Store| {
            st.snapshot()
                .unwrap()
                .machine(&m.id())
                .and_then(|m| m.last_status.clone())
                .unwrap()
        };
        let s = last(&st);
        assert_eq!(
            (s.left, s.idle, s.allow, s.reported_at),
            (Some(13_680), Some(720), Some(14_400), t)
        );
        // a CLI that sends neither
        st.apply_status(m.id(), status(2, None, None), 0).unwrap();
        let s = last(&st);
        assert_eq!((s.left, s.idle, s.allow), (Some(13_680), None, None));
    }

    #[test]
    fn a_hand_back_report_does_not_reopen_a_cancelled_plan() {
        let st = store();
        let m = paired(&st);
        let t0 = MIDNIGHT + 9 * H;
        st.set_now(t0);
        let plan = |state: &str| LocalEvent::PutPlan {
            plan: PlanApprovalRecord {
                machine: m.id(),
                request_id: "d1".into(),
                plan_hash: "h".into(),
                not_before: t0,
                state: state.into(),
                ..PlanApprovalRecord::default()
            },
        };
        st.apply_local(plan("approved")).unwrap();
        st.apply_local(plan("cancelled")).unwrap();
        // A report of a hand-back for the same plan arrives after the cancel.
        let r = request_with(&m, "report", t0 + MIN, |b| {
            b.handback = Some(sealctl_core::wire::Handback {
                hash: "h".into(),
                ..Default::default()
            });
        });
        st.set_now(t0 + MIN);
        st.apply_report(r, 0).unwrap();
        let l = st.local().unwrap();
        assert_eq!(l.plans[0].state, "cancelled");
        // Within its window the plan still answers nothing by itself.
        let mut c = crate::decide::DecideContext {
            now: t0 + 2 * MIN,
            utc_offset_secs: 0,
            phone_unlocked: true,
            near: true,
            on_wifi: true,
            location: crate::decide::LocationAccess::Always,
            current_place: None,
            current_place_settled: false,
            day: None,
            answers: Vec::new(),
            session_open: false,
            hold: None,
            biometrics: crate::decide::Biometrics::Available,
            plan: Some(l.plans[0].clone()),
        };
        let f = crate::decide::RequestFacts {
            kind: Some(RequestKind::Unseal),
            level: 2,
            machine: m.id(),
            plan_hash: Some("h".into()),
            has_keys: true,
            ..Default::default()
        };
        assert_ne!(
            crate::decide::decide_facts(&f, &c).asking,
            crate::decide::Asking::PlanKeys
        );
        c.plan.as_mut().unwrap().state = "done".into();
        assert_eq!(
            crate::decide::decide_facts(&f, &c).asking,
            crate::decide::Asking::PlanKeys
        );
    }

    #[test]
    fn a_clock_set_back_keeps_message_seqs_rising_and_ids_refused() {
        let st = store();
        let t0 = MIDNIGHT + 9 * H;
        st.set_now(t0);
        let a = st.next_message_seq("m".into()).unwrap();
        assert!(st.see_request("r".into(), "m".into(), 0).unwrap());
        st.close_request("r".into(), "answered".into()).unwrap();
        // The clock goes back an hour: the machine still sees a larger seq, and the answered
        // id is still refused (it is kept longer, never shorter).
        st.set_now(t0 - H);
        let b = st.next_message_seq("m".into()).unwrap();
        assert!(b > a);
        assert!(!st.see_request("r".into(), "m".into(), 0).unwrap());
        // Seqs of two machines are separate.
        assert_eq!(st.next_message_seq("n".into()).unwrap(), t0 - H);
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
    fn re_pairing_beats_a_tombstone_from_a_clock_ahead() {
        let st = store();
        let key = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";
        st.apply(Event::PairMachine {
            machine: machine(key, "dev@mbp"),
            replaces: None,
        })
        .unwrap();
        st.apply(Event::UnpairMachine { key: key.into() }).unwrap();
        // The removal was made on a device whose clock ran a day ahead.
        let c = lock(&st.conn).unwrap();
        let mut s: State = read_doc(&c, "state").unwrap();
        s.machines[0].updated = TEST_EPOCH_MS + 86_400_000;
        write_doc(&c, "state", &s).unwrap();
        drop(c);
        let removed = st.snapshot().unwrap();
        let s = st
            .apply(Event::PairMachine {
                machine: machine(key, "dev@mbp"),
                replaces: None,
            })
            .unwrap();
        let merged = crate::merge::merge_state(removed, s);
        assert_eq!(merged.live_machines().count(), 1);
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
        st.set_now(TEST_EPOCH_MS + 15 * MIN);
        assert!(!st.see_request("r2".into(), "m".into(), 1).unwrap());
        // Dropped once that time has passed, however late the relay says they expire.
        st.set_now(TEST_EPOCH_MS + 31 * MIN);
        assert!(st.see_request("r4".into(), "m".into(), u64::MAX).unwrap());
        let c = lock(&st.conn).unwrap();
        let l: LocalState = read_doc(&c, "local").unwrap();
        let ids: Vec<&str> = l.pending.iter().map(|p| p.id.as_str()).collect();
        assert_eq!(ids, ["r4"]);
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
        let t = TEST_EPOCH_MS - 60_000;
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
            0,
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
            0,
        )
        .unwrap();
        assert_eq!(st.usage(None, None, 100).unwrap().len(), 4);
        assert_eq!(total(&st), 4);
    }

    /// The daily counts of `day` as (used, declined).
    fn counted(st: &Store, day: &str, offset: i32) -> (u64, u64) {
        st.daily_counts(day.into(), day.into(), offset)
            .unwrap()
            .first()
            .map_or((0, 0), |d| (d.used, d.declined))
    }

    const DAY: u64 = 24 * H;

    #[test]
    fn a_resent_log_is_counted_once_a_day() {
        use sealctl_core::wire::{LogEntry, MachineStatus};
        let st = store();
        let m = paired(&st);
        let t = MIDNIGHT + 10 * H;
        st.set_now(t);
        let entry = |n: u64, names: &[&str]| LogEntry {
            time: t - 30 * MIN + n,
            command: "env".into(),
            names: names.iter().map(|n| (*n).to_owned()).collect(),
            ..LogEntry::default()
        };
        let status = |seq, log| MachineStatus {
            seq,
            log,
            ..MachineStatus::default()
        };
        let first = vec![entry(1, &["A", "B"]), entry(2, &["C"])];
        st.apply_status(m.id(), status(1, first.clone()), 0)
            .unwrap();
        assert_eq!(counted(&st, "2026-11-21", 0), (3, 0));
        // resent, unacknowledged, with one new use
        let mut second = first;
        second.push(entry(3, &["D"]));
        st.apply_status(m.id(), status(2, second), 0).unwrap();
        assert_eq!(counted(&st, "2026-11-21", 0), (4, 0));
        // a deny counts as declined, an expired answer as nothing
        let r = request_at(&m, "open", t, Vec::new());
        st.answered(r, "denied".into(), false, false, None, false, 0)
            .unwrap();
        let r = request_at(&m, "open", t, Vec::new());
        st.answered(r, "expired".into(), false, false, None, false, 0)
            .unwrap();
        assert_eq!(counted(&st, "2026-11-21", 0), (4, 1));
        // the same figures as the month
        let month = st.summary("2026-11".into()).unwrap();
        assert_eq!((month.keys_used, month.requests_declined), (4, 1));
    }

    #[test]
    fn an_entry_older_than_the_kept_rows_is_neither_logged_nor_counted() {
        use sealctl_core::wire::{LogEntry, MachineStatus};
        let st = store();
        let m = paired(&st);
        let t = MIDNIGHT + 10 * H;
        st.set_now(t);
        let used = LogEntry {
            time: t,
            command: "env".into(),
            names: vec!["A".into()],
            ..LogEntry::default()
        };
        let status = |seq, log| MachineStatus {
            seq,
            log,
            ..MachineStatus::default()
        };
        st.apply_status(m.id(), status(1, vec![used.clone()]), 0)
            .unwrap();
        assert_eq!(counted(&st, "2026-11-21", 0), (1, 0));
        // 91 days on the row is pruned; the machine (back from a long trip, its log never
        // acknowledged) resends the entry and one from 89 days ago.
        let later = t + 91 * DAY;
        st.set_now(later);
        st.prune(later, 0).unwrap();
        assert!(st.usage(None, None, 10).unwrap().is_empty());
        let recent = LogEntry {
            time: later - 89 * DAY,
            ..used.clone()
        };
        st.apply_status(m.id(), status(2, vec![used, recent]), 0)
            .unwrap();
        // the old one is skipped, so it is not counted a second time; the recent one counts
        let today = local_date(later, 0);
        assert_eq!(counted(&st, "2026-11-21", 0), (1, 0));
        assert_eq!(counted(&st, &today, 0), (1, 0));
        let log = st.usage(None, None, 10).unwrap();
        assert_eq!(log.len(), 1);
        assert_eq!(log[0].time, later - 89 * DAY);
        assert_eq!(st.summary(local_month(later, 0)).unwrap().keys_used, 1);
    }

    #[test]
    fn rows_are_kept_90_days_and_counts_400() {
        let st = store();
        let m = paired(&st);
        let now = MIDNIGHT + 12 * H;
        let at = |days_ago: u64| now - days_ago * DAY;
        for days_ago in [402, 398, 91, 89, 0] {
            st.set_now(at(days_ago));
            let r = request_at(&m, "open", at(days_ago), Vec::new());
            st.answered(r, "one_tap".into(), true, false, None, false, 0)
                .unwrap();
        }
        st.prune(now, 0).unwrap();
        let log: Vec<u64> = st
            .usage(None, None, 10)
            .unwrap()
            .iter()
            .map(|u| u.time)
            .collect();
        assert_eq!(log, [at(0), at(89)]);
        let days: Vec<String> = st
            .daily_counts("2000-01-01".into(), "2100-01-01".into(), 0)
            .unwrap()
            .into_iter()
            .map(|d| d.day)
            .collect();
        let want: Vec<String> = [398, 91, 89, 0]
            .iter()
            .map(|d| local_date(at(*d), 0))
            .collect();
        assert_eq!(days, want);
    }

    #[test]
    fn a_use_near_midnight_counts_on_the_phone_s_local_day() {
        use sealctl_core::wire::{LogEntry, MachineStatus};
        let st = store();
        let m = paired(&st);
        let utc2 = 2 * 3600;
        // 23:59 on 2026-11-21 at UTC+2 is 21:59 UTC
        let before = MIDNIGHT + 22 * H - MIN;
        st.set_now(before);
        let r = request_at(&m, "open", before, Vec::new());
        st.answered(r, "one_tap".into(), true, false, None, false, utc2)
            .unwrap();
        assert_eq!(counted(&st, "2026-11-21", utc2), (1, 0));
        // two minutes later it is the 22nd there
        let after = before + 2 * MIN;
        st.set_now(after);
        let r = request_at(&m, "open", after, Vec::new());
        st.answered(r, "denied".into(), false, false, None, false, utc2)
            .unwrap();
        assert_eq!(counted(&st, "2026-11-22", utc2), (0, 1));
        // a use made at 23:59 and reported at 00:01 counts when it reached the phone, as the
        // month does
        st.apply_status(
            m.id(),
            MachineStatus {
                seq: 1,
                log: vec![LogEntry {
                    time: before,
                    command: "env".into(),
                    names: vec!["A".into()],
                    ..LogEntry::default()
                }],
                ..MachineStatus::default()
            },
            utc2,
        )
        .unwrap();
        assert_eq!(counted(&st, "2026-11-21", utc2), (1, 0));
        assert_eq!(counted(&st, "2026-11-22", utc2), (1, 1));
    }

    #[test]
    fn the_counts_are_backfilled_once_from_an_older_database() {
        let dir = std::env::temp_dir().join(format!(
            "sealctl-backfill-{}-{:?}",
            std::process::id(),
            std::thread::current().id()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("old.db");
        let _ = std::fs::remove_file(&path);
        // A database as the version before the daily counts left it.
        let now = MIDNIGHT + 12 * H;
        {
            let c = Connection::open(&path).unwrap();
            c.execute_batch(
                "CREATE TABLE doc (key TEXT PRIMARY KEY, json TEXT NOT NULL);
                 CREATE TABLE usage (
                   id INTEGER PRIMARY KEY AUTOINCREMENT,
                   time INTEGER NOT NULL, machine TEXT NOT NULL, key TEXT NOT NULL,
                   json TEXT NOT NULL);",
            )
            .unwrap();
            let row = |time: u64, outcome: &str| UsageEntry {
                time,
                machine: "m".into(),
                key: "K".into(),
                outcome: outcome.into(),
                ..UsageEntry::default()
            };
            for e in [
                row(now - 200 * DAY, "one_tap"),
                row(now - 200 * DAY, "denied"),
                row(now - 2 * DAY, "in_session"),
                row(now - 2 * DAY, "expired"),
                // 23:30 UTC: the next day at UTC+1
                row(MIDNIGHT - 30 * MIN, "automatic"),
            ] {
                insert_usage(&c, &e).unwrap();
            }
        }
        let st = Store::open(path.to_string_lossy().into_owned()).unwrap();
        st.set_now(now);
        let m = paired(&st);
        // A use recorded before the first prune counts once, live.
        let r = request_at(&m, "open", now, Vec::new());
        st.answered(r, "one_tap".into(), true, false, None, false, 3600)
            .unwrap();
        // The first prune removes the rows older than 90 days, after counting them.
        st.prune(now, 3600).unwrap();
        st.prune(now, 3600).unwrap();
        assert_eq!(st.usage(None, None, 10).unwrap().len(), 4);
        assert_eq!(
            counted(&st, &local_date(now - 200 * DAY, 3600), 3600),
            (1, 1)
        );
        assert_eq!(counted(&st, &local_date(now - 2 * DAY, 3600), 3600), (1, 0));
        assert_eq!(counted(&st, "2026-11-21", 3600), (2, 0));
        // Opened again, nothing is counted twice.
        drop(st);
        let st = Store::open(path.to_string_lossy().into_owned()).unwrap();
        st.set_now(now);
        assert_eq!(counted(&st, "2026-11-21", 3600), (2, 0));
        assert_eq!(
            counted(&st, &local_date(now - 200 * DAY, 3600), 3600),
            (1, 1)
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_new_database_has_nothing_to_backfill() {
        let st = store();
        let c = lock(&st.conn).unwrap();
        let mark: DailyBackfill = read_doc(&c, DAILY_BACKFILL).unwrap();
        assert_eq!(mark.upto, 0);
    }

    #[test]
    fn the_usage_log_records_what_its_key_names() {
        use sealctl_core::wire::{AgentUse, RequestContext, RequestItem, Subject};
        let st = store();
        let m = paired(&st);
        let t = TEST_EPOCH_MS - 60_000;
        let ctx = |subject: Option<(&str, &str)>, cmd: &str| {
            Some(RequestContext {
                command: cmd.into(),
                subject: subject.map(|(k, n)| Subject {
                    kind: k.into(),
                    name: n.into(),
                }),
                ..RequestContext::default()
            })
        };
        let item = |p: &str| RequestItem {
            purpose: p.into(),
            id: "a7c3e9f1-2b4d-4e6f-8a0c-1d3e5f7a9b42".into(),
            ..RequestItem::default()
        };
        let cases: Vec<(Arc<Request>, &str, Option<&str>)> = vec![
            (
                request_with(&m, "keys", t, |b| {
                    b.ctx = ctx(Some(("volume", "safe")), "");
                    b.keys = vec![item("volume")];
                }),
                "safe",
                Some("volume"),
            ),
            (
                request_with(&m, "keys", t + 1, |b| {
                    b.lvl = Some(2);
                    b.ctx = ctx(Some(("machine", "seal")), "seal volume safe x");
                    b.keys = vec![item("volume")];
                }),
                "seal",
                Some("machine"),
            ),
            (
                request_with(&m, "open", t + 2, |b| {
                    b.ctx = ctx(None, "sealctl unseal");
                    b.keys = vec![item("secrets")];
                }),
                "secrets a7c3e9f1-2b4d-4e6f-8a0c-1d3e5f7a9b42",
                Some("secrets"),
            ),
            (
                request_at(
                    &m,
                    "agent",
                    t + 3,
                    vec![AgentUse {
                        agent: "claude".into(),
                        repository: "r".into(),
                        names: vec!["shop/K".into()],
                    }],
                ),
                "shop/K",
                Some("secret"),
            ),
        ];
        for (req, key, kind) in cases {
            st.answered(req, "once".into(), true, false, None, false, 0)
                .unwrap();
            let u = st.usage(None, None, 1).unwrap().remove(0);
            assert_eq!((u.key.as_str(), u.kind.as_deref()), (key, kind));
        }
        // Without a kind, the JSON is what versions before it wrote: a session's use a machine
        // reports again is still found as already recorded.
        let old = r#"{"time":1,"machine":"m","key":"safe","agent":null,"repo":null,"command":null,"outcome":"once"}"#;
        let e: UsageEntry = serde_json::from_str(old).unwrap();
        assert_eq!(e.kind, None);
        assert_eq!(serde_json::to_string(&e).unwrap(), old);
    }

    #[test]
    fn pending_ids_refuse_replays() {
        let st = store();
        let far = TEST_EPOCH_MS + 60_000;
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
        st.prune(TEST_EPOCH_MS, 0).unwrap();
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

    // ---------- the corrected clock (SPEC.md 8.1): a clock set forward ends no wait early ----------

    use crate::decide::{
        decide_facts, Asking, Biometrics, DecideContext, RequestFacts, DELAY_SECS, HOLD_MS,
    };
    use sealctl_core::{RefuseReason, RequestKind};

    /// The relay's time learned at `t` (health on foreground).
    fn reach_relay(st: &Store, t: u64) {
        st.set_now(t);
        st.relay_time(t).unwrap();
    }

    fn unseal(level: u8) -> RequestFacts {
        RequestFacts {
            kind: Some(RequestKind::Unseal),
            level,
            has_match: true,
            machine: "m".into(),
            plan_hash: Some("plan-1".into()),
            has_keys: true,
            ..RequestFacts::default()
        }
    }

    /// The context the apps build: `now` and the place's settling from the store's clock.
    fn ctx_now(st: &Store, place: Option<&TrustedPlace>) -> DecideContext {
        let l = st.local().unwrap();
        DecideContext {
            now: st.clock_now().unwrap().now,
            utc_offset_secs: 0,
            phone_unlocked: true,
            near: true,
            on_wifi: true,
            location: crate::decide::LocationAccess::Always,
            current_place: place.map(|p| p.id.clone()),
            current_place_settled: place.is_some_and(|p| st.place_settled_now(p.clone()).unwrap()),
            day: None,
            answers: Vec::new(),
            session_open: false,
            hold: l.holds.first().cloned(),
            biometrics: Biometrics::Available,
            plan: l.plans.first().cloned(),
        }
    }

    #[test]
    fn a_clock_set_forward_does_not_end_a_hold() {
        let st = store();
        let t0 = MIDNIGHT + 9 * H;
        reach_relay(&st, t0);
        // A wrong number: held for an hour on the corrected clock.
        let until = st.clock_now().unwrap().now + HOLD_MS;
        st.apply_local(LocalEvent::SetHold {
            hold: Hold {
                machine: "m".into(),
                until,
            },
        })
        .unwrap();
        // Ten minutes later the phone's clock is set two hours forward.
        st.pass(10 * MIN);
        st.set_system_clock(t0 + 2 * H);
        assert_eq!(st.clock_now().unwrap().now, t0 + 10 * MIN);
        let v = decide_facts(&unseal(2), &ctx_now(&st, None));
        assert_eq!(v.asking, Asking::Refused);
        assert_eq!(v.refuse, Some(RefuseReason::Held));
        // A change of the local records caps the hold on the corrected clock: still an hour.
        let l = st.apply_local(LocalEvent::AgentNoteShown).unwrap();
        assert_eq!(l.holds[0].until, t0 + H);
        // A clock set back instead does not shorten a hold recorded after it.
        st.set_system_clock(t0 - 3 * H);
        assert_eq!(st.clock_now().unwrap().now, t0 + 10 * MIN);
        // The hour really passes.
        st.pass(50 * MIN);
        let v = decide_facts(&unseal(2), &ctx_now(&st, None));
        assert_ne!(v.asking, Asking::Refused);
    }

    fn hand_added(st: &Store) -> TrustedPlace {
        st.apply(Event::AddPlace {
            place: TrustedPlace {
                id: "home".into(),
                name: "Home".into(),
                radius: 150.0,
                manual: true,
                ..TrustedPlace::default()
            },
        })
        .unwrap()
        .places
        .into_iter()
        .find(|p| p.id == "home")
        .unwrap()
    }

    #[test]
    fn a_clock_set_forward_does_not_end_a_hand_added_place_s_day() {
        let st = store();
        let t0 = MIDNIGHT + 9 * H;
        reach_relay(&st, t0);
        // Added with the clock set two days back: stamped on the corrected clock.
        st.set_system_clock(t0 - 48 * H);
        let place = hand_added(&st);
        assert_eq!(place.created, t0);
        // An hour later the clock is set 25 hours forward: the level 3 delay still applies.
        st.pass(H);
        st.set_system_clock(t0 + 25 * H);
        assert!(!st.place_settled_now(place.clone()).unwrap());
        let v = decide_facts(&unseal(3), &ctx_now(&st, Some(&place)));
        assert_eq!(v.delay_secs, DELAY_SECS);
        // A day passes on the since-boot clock; the relay's time is learned again.
        st.pass(23 * H);
        reach_relay(&st, t0 + 24 * H);
        assert!(st.place_settled_now(place.clone()).unwrap());
        let v = decide_facts(&unseal(3), &ctx_now(&st, Some(&place)));
        assert_eq!(v.delay_secs, 0);
    }

    #[test]
    fn a_place_added_by_hand_on_a_stale_clock_starts_its_day_once_the_clock_is_fresh() {
        let st = store();
        let t0 = MIDNIGHT + 9 * H;
        reach_relay(&st, t0);
        // After a reboot the clock is stale; two days later, offline, the clock is set back.
        st.reboot(5 * MIN);
        st.set_system_clock(t0 - 5 * H);
        assert!(!st.clock_now().unwrap().fresh);
        // The stale clock reads the last relay time, two days old: the place is not stamped.
        let place = hand_added(&st);
        assert_eq!(place.created, 0);
        assert!(!st.place_settled_now(place).unwrap());
        // The relay is reached two days on: the place's two hours start then, not before.
        reach_relay(&st, t0 + 48 * H);
        let place = st
            .snapshot()
            .unwrap()
            .places
            .into_iter()
            .find(|p| p.id == "home")
            .unwrap();
        assert_eq!(place.created, t0 + 48 * H);
        assert!(st.local().unwrap().dirty);
        assert!(!st.place_settled_now(place.clone()).unwrap());
        let v = decide_facts(&unseal(3), &ctx_now(&st, Some(&place)));
        assert_eq!(v.delay_secs, DELAY_SECS);
        // A day later on the fresh clock it lifts the delay.
        st.pass(24 * H);
        assert!(st.place_settled_now(place).unwrap());
    }

    #[test]
    fn a_learned_place_is_stamped_at_once_and_one_added_by_hand_when_the_relay_is_reached() {
        let st = store();
        let t0 = MIDNIGHT + 9 * H;
        st.set_now(t0);
        let place = hand_added(&st);
        assert_eq!(place.created, 0);
        // A learned place is stamped whatever the clock.
        let learned = st
            .apply(Event::AddPlace {
                place: TrustedPlace {
                    id: "work".into(),
                    name: "Work".into(),
                    radius: 150.0,
                    ..TrustedPlace::default()
                },
            })
            .unwrap()
            .places
            .into_iter()
            .find(|p| p.id == "work")
            .unwrap();
        assert_eq!(learned.created, t0);
        reach_relay(&st, t0 + H);
        let home = st
            .snapshot()
            .unwrap()
            .places
            .into_iter()
            .find(|p| p.id == "home")
            .unwrap();
        assert_eq!(home.created, t0 + H);
    }

    #[test]
    fn a_stale_clock_never_lifts_the_delay_at_a_hand_added_place() {
        let st = store();
        let t0 = MIDNIGHT + 9 * H;
        reach_relay(&st, t0);
        let place = hand_added(&st);
        // Unknown: a phone that never reached the relay counts on nothing it can't check.
        let fresh = store();
        fresh.set_now(t0);
        let p2 = hand_added(&fresh);
        fresh.set_now(t0 + 30 * H);
        assert!(!fresh.clock_now().unwrap().fresh);
        assert!(!fresh.place_settled_now(p2).unwrap());
        // After a reboot, offline, with the clock set forward: stale, so not settled.
        st.reboot(5 * MIN);
        st.set_system_clock(t0 + 30 * H);
        let now = st.clock_now().unwrap();
        assert!(!now.fresh);
        assert_eq!(now.now, t0 + 30 * H);
        assert!(!st.place_settled_now(place.clone()).unwrap());
        // A clock set back while stale: the last relay time is the floor.
        st.set_system_clock(t0 - 5 * H);
        assert_eq!(st.clock_now().unwrap().now, t0);
        // A learned place is settled at once whatever the clock.
        let learned = TrustedPlace {
            manual: false,
            ..place.clone()
        };
        assert!(st.place_settled_now(learned).unwrap());
        // Reaching the relay a day on settles the hand-added place.
        reach_relay(&st, t0 + 25 * H);
        assert!(st.place_settled_now(place).unwrap());
    }

    #[test]
    fn a_clock_set_forward_does_not_shorten_the_level_3_wait() {
        let st = store();
        let t0 = MIDNIGHT + 9 * H;
        reach_relay(&st, t0);
        // A level 3 approval away from a trusted place: the plan hands out keys two hours on.
        let not_before = st.clock_now().unwrap().now + u64::from(DELAY_SECS) * 1000;
        st.apply_local(LocalEvent::PutPlan {
            plan: PlanApprovalRecord {
                machine: "m".into(),
                request_id: "r1".into(),
                plan_hash: "plan-1".into(),
                not_before,
                state: "delayed".into(),
                all: true,
                ..PlanApprovalRecord::default()
            },
        })
        .unwrap();
        // Twenty minutes on, the clock is set three hours forward: no keys yet.
        st.pass(20 * MIN);
        st.set_system_clock(t0 + 3 * H);
        let v = decide_facts(&unseal(3), &ctx_now(&st, None));
        assert_ne!(v.asking, Asking::PlanKeys);
        // The two hours pass.
        st.pass(100 * MIN);
        let v = decide_facts(&unseal(3), &ctx_now(&st, None));
        assert_eq!(v.asking, Asking::PlanKeys);
    }

    #[test]
    fn a_signed_call_that_disagrees_makes_the_clock_stale() {
        let st = store();
        let t0 = MIDNIGHT + 9 * H;
        reach_relay(&st, t0);
        let place = hand_added(&st);
        st.pass(25 * H);
        reach_relay(&st, t0 + 25 * H);
        assert!(st.place_settled_now(place.clone()).unwrap());
        // Within the signature window: still fresh.
        st.relay_accepted(t0 + 25 * H + 4 * MIN).unwrap();
        assert!(st.clock_now().unwrap().fresh);
        // The relay accepted a time 20 minutes off: the learned time can't be right.
        st.relay_accepted(t0 + 25 * H + 20 * MIN).unwrap();
        assert!(!st.clock_now().unwrap().fresh);
        assert!(!st.place_settled_now(place).unwrap());
    }
}
