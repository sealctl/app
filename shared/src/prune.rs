//! Lifetimes (SPEC.md 6.4): answers unused for 90 days go, machines unseen for 90 days are
//! flagged, inventory unseen for a year is stale, tombstones older than 90 days are dropped,
//! summaries older than 12 months are dropped.

use crate::model::State;

/// 90 days in ms.
pub const NINETY_DAYS_MS: u64 = 90 * 86_400_000;
/// 365 days in ms.
pub const YEAR_MS: u64 = 365 * 86_400_000;

/// Applies the lifetimes at `now`; changed records get `updated = now`.
pub fn prune_state(mut s: State, now: u64) -> State {
    let old = now.saturating_sub(NINETY_DAYS_MS);
    for a in s.answers.iter_mut().filter(|a| !a.deleted) {
        if a.last_used.max(a.created) < old {
            a.deleted = true;
            a.updated = now;
        }
    }
    for m in s.machines.iter_mut().filter(|m| !m.deleted) {
        let seen = m.last_seen.unwrap_or(m.paired_at).max(m.paired_at);
        let flag = seen < old;
        if flag != m.flagged {
            m.flagged = flag;
            m.updated = now;
        }
    }
    let year = now.saturating_sub(YEAR_MS);
    for i in s.inventory.iter_mut().filter(|i| !i.deleted) {
        let stale = i.last_use.max(i.first_use) < year;
        if stale != i.stale {
            i.stale = stale;
            i.updated = now;
        }
    }
    s.machines.retain(|m| !m.deleted || m.updated >= old);
    s.answers.retain(|a| !a.deleted || a.updated >= old);
    s.places.retain(|p| !p.deleted || p.updated >= old);
    s.inventory.retain(|i| !i.deleted || i.updated >= old);
    s.summaries.sort_by(|a, b| b.month.cmp(&a.month));
    s.summaries.truncate(12);
    s.summaries.sort_by(|a, b| a.month.cmp(&b.month));
    s
}

/// Days until an answer is removed (SPEC.md 11.10: "Unused for 80 days. Removed in 10 days.").
#[uniffi::export]
pub fn answer_days_left(last_used: u64, now: u64) -> i64 {
    let used = (now.saturating_sub(last_used) / 86_400_000) as i64;
    90 - used
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::{InventoryItem, Machine, MonthSummary, RememberedAnswer};

    const NOW: u64 = 1_795_251_720_000;
    const D: u64 = 86_400_000;

    #[test]
    fn lifetimes() {
        let mut s = State::default();
        s.answers.push(RememberedAnswer {
            agent: "a".into(),
            last_used: NOW - 91 * D,
            ..RememberedAnswer::default()
        });
        s.answers.push(RememberedAnswer {
            agent: "b".into(),
            last_used: NOW - 10 * D,
            ..RememberedAnswer::default()
        });
        s.machines.push(Machine {
            key: "m1".into(),
            paired_at: NOW - 200 * D,
            last_seen: Some(NOW - 94 * D),
            ..Machine::default()
        });
        s.machines.push(Machine {
            key: "m2".into(),
            paired_at: NOW - 200 * D,
            last_seen: Some(NOW - D),
            ..Machine::default()
        });
        s.machines.push(Machine {
            key: "m3".into(),
            deleted: true,
            updated: NOW - 100 * D,
            ..Machine::default()
        });
        s.inventory.push(InventoryItem {
            id: "i".into(),
            last_use: NOW - 400 * D,
            ..InventoryItem::default()
        });
        for m in 1..=14 {
            s.summaries.push(MonthSummary {
                month: format!("2025-{m:02}")
                    .replace("2025-13", "2026-01")
                    .replace("2025-14", "2026-02"),
                ..MonthSummary::default()
            });
        }
        let p = prune_state(s, NOW);
        assert!(p.answers[0].deleted && !p.answers[1].deleted);
        assert!(p.machines[0].flagged && !p.machines[1].flagged);
        assert_eq!(p.machines.len(), 2);
        assert!(p.inventory[0].stale);
        assert_eq!(p.summaries.len(), 12);
        assert_eq!(p.summaries[0].month, "2025-03");
        assert_eq!(answer_days_left(NOW - 80 * D, NOW), 10);
    }
}
