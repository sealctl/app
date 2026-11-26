//! The phone's records (SPEC.md 6.4). "Relay" records live in [`State`], which is sealed into
//! the relay state blob; "Local" records stay in the phone database only ([`LocalState`]).
//!
//! Every relay record carries `updated` (Unix ms) and `deleted` (a tombstone kept 90 days), so
//! two installs' versions merge record by record ([`crate::merge`]).

use serde::{Deserialize, Serialize};

use sealctl_core::wire::PlanItem;
use sealctl_core::KeyRef;

/// The last status a machine reported (machine channel or `report`).
#[derive(uniffi::Record, Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct SessionStatus {
    /// `locked`, `open` or `waiting`.
    pub session: String,
    /// Idle seconds left when reported.
    pub left: Option<u64>,
    /// Seconds since the machine's last work moment when reported; `None` from a CLI that does
    /// not send it.
    pub idle: Option<u64>,
    /// The machine's idle allowance when reported, seconds; `None` from a CLI that does not
    /// send it.
    pub allow: Option<u64>,
    /// Hard stop, Unix ms.
    pub stop: Option<u64>,
    /// TrustedPlace kind from the last open.
    pub place: Option<String>,
    /// When the phone received it, Unix ms.
    pub reported_at: u64,
    /// The status `seq`.
    pub seq: u64,
}

/// A paired machine.
#[derive(uniffi::Record, Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Machine {
    /// Pairing key `M`, 43 characters.
    pub key: String,
    /// Machine box key `MX` from the pairing offer; messages are sealed to it.
    pub box_key: String,
    /// `user@host`.
    pub name: String,
    /// OS name and version.
    pub os: String,
    /// Hardware model.
    pub model: Option<String>,
    /// Hardware hint; kept only in the encrypted state, never sent to the relay.
    pub hint: Option<String>,
    /// Unix ms.
    pub paired_at: u64,
    /// 1 to 40 characters.
    pub nickname: Option<String>,
    /// The relay's `lastSeen`, Unix ms.
    pub last_seen: Option<u64>,
    /// Last reported state.
    pub last_status: Option<SessionStatus>,
    /// Show the `#tag` after the name (another machine has the same name).
    pub tag_shown: bool,
    /// Unseen for 90 days.
    pub flagged: bool,
    /// Relay origin it was paired through.
    pub relay: String,
    /// Unix ms.
    pub updated: u64,
    /// Tombstone.
    pub deleted: bool,
}

/// A remembered answer: this agent may use this key in this repository.
#[derive(uniffi::Record, Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct RememberedAnswer {
    /// Agent name as sent (`claude`, …).
    pub agent: String,
    /// Secret name.
    pub key_name: String,
    /// Stable repository id.
    pub repo_id: String,
    /// Repository name for display.
    pub repo_name: String,
    /// Unix ms.
    pub created: u64,
    /// Unix ms.
    pub last_used: u64,
    /// Unix ms.
    pub updated: u64,
    /// Tombstone.
    pub deleted: bool,
}

/// A trusted place.
#[derive(uniffi::Record, Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct TrustedPlace {
    /// Random id.
    pub id: String,
    /// Named by the user.
    pub name: String,
    /// Centre latitude.
    pub lat: f64,
    /// Centre longitude.
    pub lon: f64,
    /// Metres (150).
    pub radius: f64,
    /// Unix ms.
    pub created: u64,
    /// Unix ms.
    pub updated: u64,
    /// Tombstone.
    pub deleted: bool,
    /// Added by hand ("Trust where I am now") rather than learned over three mornings: it counts
    /// for the level 3 delay only 24 hours after `created` (SPEC.md 9.6).
    pub manual: bool,
}

/// One derived key the phone handed out, on one machine.
#[derive(uniffi::Record, Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct InventoryItem {
    /// `secrets`, `secret`, `volume`, `backup`.
    pub purpose: String,
    /// Object id.
    pub id: String,
    /// Words fingerprint.
    pub words: String,
    /// Key check.
    pub check: String,
    /// Machine key.
    pub machine: String,
    /// Path or URL.
    pub path: String,
    /// Bytes.
    pub size: u64,
    /// Unix ms.
    pub first_use: u64,
    /// Unix ms.
    pub last_use: u64,
    /// Unseen for a year.
    pub stale: bool,
    /// Unix ms.
    pub updated: u64,
    /// Tombstone.
    pub deleted: bool,
}

/// Monthly figures (SPEC.md 11.12).
#[derive(uniffi::Record, Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct MonthSummary {
    /// `YYYY-MM`.
    pub month: String,
    /// Keys used.
    pub keys_used: u64,
    /// Deny answers.
    pub requests_declined: u64,
    /// Machines that used keys.
    pub machines: Vec<String>,
    /// Unix ms.
    pub updated: u64,
}

/// A retired card.
#[derive(uniffi::Record, Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct RetiredCard {
    /// Its words fingerprint.
    pub fingerprint: String,
    /// `YYYY-MM-DD`.
    pub retired_on: String,
}

/// Facts about the current words (never the words).
#[derive(uniffi::Record, Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct WordsInfo {
    /// 4 characters.
    pub fingerprint: String,
    /// `YYYY-MM-DD`, set when the card check passes.
    pub written_on: String,
    /// `YYYY-MM-DD` of the last yearly check.
    pub last_check: Option<String>,
    /// Retired cards.
    pub retired: Vec<RetiredCard>,
    /// Unix ms.
    pub updated: u64,
}

/// Settings the user can change (SPEC.md 2 rule 8: backups only).
#[derive(uniffi::Record, Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Settings {
    /// Encrypted backup on the relay.
    pub relay_backup: bool,
    /// iCloud Keychain / Block Store copy of the words.
    pub keychain_backup: bool,
    /// Unix ms.
    pub updated: u64,
}

impl Default for Settings {
    fn default() -> Self {
        Self {
            relay_backup: true,
            keychain_backup: true,
            updated: 0,
        }
    }
}

/// One item of a hand-back report.
#[derive(uniffi::Record, Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct ReportItem {
    /// Plan item kind.
    pub kind: String,
    /// Plan item name.
    pub name: String,
    /// Where it went.
    pub to: String,
    /// `done`, `failed`, `skipped`.
    pub state: String,
}

/// What a level 3 action did (SPEC.md 11.23 Report).
#[derive(uniffi::Record, Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct HandbackReport {
    /// Random id.
    pub id: String,
    /// Machine key, or empty for an action on the phone.
    pub machine: String,
    /// Display name at the time.
    pub machine_name: String,
    /// `unseal`, `leave`, `words`, `delete`.
    pub what: String,
    /// Plan hash.
    pub plan_hash: String,
    /// Items.
    pub items: Vec<ReportItem>,
    /// Run folder on the machine.
    pub run: String,
    /// Unix ms.
    pub time: u64,
    /// Unix ms.
    pub updated: u64,
}

/// Everything sealed into the relay state blob.
#[derive(uniffi::Record, Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct State {
    /// Paired machines, tombstones included.
    pub machines: Vec<Machine>,
    /// Remembered answers.
    pub answers: Vec<RememberedAnswer>,
    /// Trusted places.
    pub places: Vec<TrustedPlace>,
    /// Inventory.
    pub inventory: Vec<InventoryItem>,
    /// Monthly summaries, 12 months.
    pub summaries: Vec<MonthSummary>,
    /// The current words.
    pub words: Option<WordsInfo>,
    /// Backups.
    pub settings: Settings,
    /// Hand-back and level 3 reports.
    pub reports: Vec<HandbackReport>,
}

impl State {
    /// Machines that are not tombstones.
    pub fn live_machines(&self) -> impl Iterator<Item = &Machine> {
        self.machines.iter().filter(|m| !m.deleted)
    }

    /// The live machine with this key.
    pub fn machine(&self, key: &str) -> Option<&Machine> {
        self.live_machines().find(|m| m.key == key)
    }

    /// Answers that are not tombstones.
    pub fn live_answers(&self) -> impl Iterator<Item = &RememberedAnswer> {
        self.answers.iter().filter(|a| !a.deleted)
    }

    /// Places that are not tombstones.
    pub fn live_places(&self) -> impl Iterator<Item = &TrustedPlace> {
        self.places.iter().filter(|p| !p.deleted)
    }
}

// ---------- local records ----------

/// A machine's day (SPEC.md 9.3): ends at the next 02:00 local or 24 h after the first
/// approval, whichever is first.
#[derive(uniffi::Record, Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct DayRecord {
    /// Machine key.
    pub machine: String,
    /// First approval, Unix ms.
    pub first_approval: u64,
    /// TrustedPlace the day began at.
    pub place_id: Option<String>,
    /// End of the day, Unix ms.
    pub ends: u64,
}

/// One use in the usage log.
#[derive(uniffi::Record, Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct UsageEntry {
    /// Unix ms.
    pub time: u64,
    /// Machine key.
    pub machine: String,
    /// Key name, object or subject.
    pub key: String,
    /// Agent or `None` for "you".
    pub agent: Option<String>,
    /// Repository name.
    pub repo: Option<String>,
    /// Command.
    pub command: Option<String>,
    /// `one_tap`, `automatic`, `in_session`, `once`, `denied`, `expired`, `confirmed`.
    pub outcome: String,
    /// What `key` names, for the Activity row ([`crate::activity`]): the request's
    /// `ctx.subject` kind (`secret`, `volume`, `backup`, `ssh`, `machine`), `secret` for a
    /// secret name, or the item's purpose when `key` is `"<purpose> <id>"`. `None` for entries
    /// written before it was recorded and for uses a machine reports from a session
    /// (`in_session`, always secret names). Left out of the JSON when `None`, so a reported
    /// entry stays equal to the one recorded before (the duplicate check compares the JSON).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub kind: Option<String>,
}

/// A request seen in the last 10 minutes.
#[derive(uniffi::Record, Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct PendingEntry {
    /// Request id.
    pub id: String,
    /// Machine key.
    pub machine: String,
    /// Unix ms.
    pub expires: u64,
    /// `waiting`, `answered`, `expired`, `ignored`.
    pub outcome: String,
    /// When it was seen.
    pub seen: u64,
}

/// A wrong number hold.
#[derive(uniffi::Record, Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Hold {
    /// Machine key.
    pub machine: String,
    /// Unix ms.
    pub until: u64,
}

/// An approved plan.
#[derive(uniffi::Record, Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct PlanApprovalRecord {
    /// Machine key.
    pub machine: String,
    /// The request that carried the approval.
    pub request_id: String,
    /// Plan hash.
    pub plan_hash: String,
    /// Plan items.
    pub items: Vec<PlanItemRecord>,
    /// Keys named by the plan.
    pub keys: Vec<KeyRefRecord>,
    /// Not before, Unix ms.
    pub not_before: u64,
    /// `approved`, `delayed`, `cancelled`, `done`.
    pub state: String,
    /// Delayed approval id, when delayed.
    pub delay_id: Option<String>,
    /// `unseal --all`.
    pub all: bool,
}

/// A plan item (serde form of the core's `PlanItem`).
#[derive(uniffi::Record, Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct PlanItemRecord {
    /// Kind.
    pub kind: String,
    /// Name.
    pub name: String,
    /// Purpose.
    pub purpose: Option<String>,
    /// Id.
    pub id: Option<String>,
}

impl From<&PlanItem> for PlanItemRecord {
    fn from(p: &PlanItem) -> Self {
        Self {
            kind: p.kind.clone(),
            name: p.name.clone(),
            purpose: p.purpose.clone(),
            id: p.id.clone(),
        }
    }
}

/// A key named by purpose and id (serde form of the core's `KeyRef`).
#[derive(uniffi::Record, Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct KeyRefRecord {
    /// Purpose.
    pub purpose: String,
    /// Id.
    pub id: String,
}

impl From<&KeyRef> for KeyRefRecord {
    fn from(k: &KeyRef) -> Self {
        Self {
            purpose: k.purpose.clone(),
            id: k.id.clone(),
        }
    }
}

impl From<&KeyRefRecord> for KeyRef {
    fn from(k: &KeyRefRecord) -> Self {
        Self {
            purpose: k.purpose.clone(),
            id: k.id.clone(),
        }
    }
}

/// A level 3 action waiting out its hour (SPEC.md 11.23 Delay).
#[derive(uniffi::Record, Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct DelayedAction {
    /// Relay delayed id (the request id for a request).
    pub id: String,
    /// `unseal_all`, `leave`, `words`, `delete`.
    pub what: String,
    /// Machine key for `unseal_all`.
    pub machine: Option<String>,
    /// Unix ms.
    pub release_at: u64,
    /// Unix ms.
    pub expires: u64,
    /// `waiting`, `released`, `cancelled`, `finished`.
    pub state: String,
    /// Who cancelled: `phone` or a machine key.
    pub cancelled_by: Option<String>,
}

/// One location sample of a place candidate.
#[derive(uniffi::Record, Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct LocationSample {
    /// Latitude.
    pub lat: f64,
    /// Longitude.
    pub lon: f64,
    /// Metres.
    pub accuracy: f64,
    /// Unix ms.
    pub time: u64,
}

/// A spot the phone approved at on several mornings.
#[derive(uniffi::Record, Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct PlaceCandidate {
    /// Random id.
    pub id: String,
    /// Mean of the samples.
    pub lat: f64,
    /// Mean of the samples.
    pub lon: f64,
    /// Samples within the last 30 days.
    pub samples: Vec<LocationSample>,
    /// Local days (`YYYY-MM-DD`) with a sample.
    pub days: Vec<String>,
    /// "Not this place".
    pub suppressed: bool,
    /// Already offered.
    pub asked: bool,
}

/// This install's push registration.
#[derive(uniffi::Record, Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct DeviceInfo {
    /// 22 characters, made once per install.
    pub device_id: String,
    /// FCM or APNs token.
    pub token: Option<String>,
    /// `fcm` or `apns`.
    pub platform: String,
    /// APNs sandbox.
    pub sandbox: bool,
    /// Last registration, Unix ms.
    pub registered: u64,
}

/// What stays on the phone only.
#[derive(uniffi::Record, Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct LocalState {
    /// Day records by machine.
    pub days: Vec<DayRecord>,
    /// Requests seen in the last 10 minutes.
    pub pending: Vec<PendingEntry>,
    /// Wrong-number holds.
    pub holds: Vec<Hold>,
    /// Approved plans.
    pub plans: Vec<PlanApprovalRecord>,
    /// Delayed actions.
    pub delayed: Vec<DelayedAction>,
    /// TrustedPlace candidates.
    pub candidates: Vec<PlaceCandidate>,
    /// Push registration.
    pub device: DeviceInfo,
    /// Onboarding step not done yet (0 when done).
    pub onboarding_step: u32,
    /// Relay state revision last seen.
    pub state_rev: u64,
    /// Last download, Unix ms.
    pub last_download: u64,
    /// Last upload, Unix ms.
    pub last_upload: u64,
    /// The state changed since the last upload.
    pub dirty: bool,
    /// The one-time agent explanation was shown (SPEC.md 11.11).
    pub agent_note_shown: bool,
    /// Last message `seq` sent, by machine.
    pub message_seq: Vec<MachineCounter>,
    /// The relay backup was shortened (SPEC.md 6.5).
    pub backup_shortened: bool,
    /// Leave sealctl progress step (0 = not leaving).
    pub leave_step: u32,
    /// Machines skipped while leaving.
    pub leave_skipped: Vec<String>,
}

/// A per-machine counter.
#[derive(uniffi::Record, Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct MachineCounter {
    /// Machine key.
    pub machine: String,
    /// Value.
    pub value: u64,
}
