//! Merging two versions of the state (SPEC.md 6.5): record by record, the later `updated`
//! wins; deletions are tombstones. Ties are broken by the record's encoding, so the result
//! does not depend on which side is local.

use std::collections::BTreeMap;

use serde::Serialize;

use crate::model::{
    HandbackReport, InventoryItem, Machine, MonthSummary, RememberedAnswer, State, TrustedPlace,
};

fn pick<T: Serialize + Clone>(a: &T, b: &T, ua: u64, ub: u64) -> T {
    match ua.cmp(&ub) {
        std::cmp::Ordering::Greater => a.clone(),
        std::cmp::Ordering::Less => b.clone(),
        std::cmp::Ordering::Equal => {
            let ea = serde_json::to_string(a).unwrap_or_default();
            let eb = serde_json::to_string(b).unwrap_or_default();
            if ea >= eb {
                a.clone()
            } else {
                b.clone()
            }
        }
    }
}

fn merge_list<T, K, F, U>(a: &[T], b: &[T], key: F, updated: U) -> Vec<T>
where
    T: Serialize + Clone,
    K: Ord,
    F: Fn(&T) -> K,
    U: Fn(&T) -> u64,
{
    let mut out: BTreeMap<K, T> = BTreeMap::new();
    for item in a.iter().chain(b.iter()) {
        let k = key(item);
        let merged = match out.get(&k) {
            Some(existing) => pick(existing, item, updated(existing), updated(item)),
            None => item.clone(),
        };
        out.insert(k, merged);
    }
    out.into_values().collect()
}

/// The merge of two states. Commutative and idempotent.
#[uniffi::export]
pub fn merge_state(local: State, remote: State) -> State {
    let summaries = merge_list(
        &local.summaries,
        &remote.summaries,
        |s: &MonthSummary| s.month.clone(),
        |s| s.updated,
    );
    State {
        machines: merge_list(
            &local.machines,
            &remote.machines,
            |m: &Machine| m.key.clone(),
            |m| m.updated,
        ),
        answers: merge_list(
            &local.answers,
            &remote.answers,
            |a: &RememberedAnswer| (a.agent.clone(), a.key_name.clone(), a.repo_id.clone()),
            |a| a.updated,
        ),
        places: merge_list(
            &local.places,
            &remote.places,
            |p: &TrustedPlace| p.id.clone(),
            |p| p.updated,
        ),
        inventory: merge_list(
            &local.inventory,
            &remote.inventory,
            |i: &InventoryItem| (i.purpose.clone(), i.id.clone(), i.machine.clone()),
            |i| i.updated,
        ),
        summaries,
        words: match (&local.words, &remote.words) {
            (Some(a), Some(b)) => Some(pick(a, b, a.updated, b.updated)),
            (a, b) => a.clone().or_else(|| b.clone()),
        },
        settings: pick(
            &local.settings,
            &remote.settings,
            local.settings.updated,
            remote.settings.updated,
        ),
        reports: merge_list(
            &local.reports,
            &remote.reports,
            |r: &HandbackReport| r.id.clone(),
            |r| r.updated,
        ),
    }
}

/// Canonical order of every list, as a merge produces.
pub fn normalise(state: State) -> State {
    merge_state(state, State::default())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::Settings;
    use proptest::prelude::*;

    fn machine(key: &str, name: &str, updated: u64, deleted: bool) -> Machine {
        Machine {
            key: key.into(),
            name: name.into(),
            updated,
            deleted,
            ..Machine::default()
        }
    }

    #[test]
    fn later_wins_and_tombstones_stay() {
        let mut a = State::default();
        let mut b = State::default();
        a.machines.push(machine("m1", "old", 1, false));
        b.machines.push(machine("m1", "new", 2, false));
        a.machines.push(machine("m2", "gone", 5, true));
        b.machines.push(machine("m2", "gone", 4, false));
        let m = merge_state(a, b);
        assert_eq!(m.machines.len(), 2);
        assert_eq!(m.machines[0].name, "new");
        assert!(m.machines[1].deleted);
    }

    #[test]
    fn settings_and_words_by_time() {
        let a = State {
            settings: Settings {
                relay_backup: false,
                keychain_backup: true,
                updated: 9,
            },
            ..State::default()
        };
        let b = State::default();
        assert!(!merge_state(a.clone(), b.clone()).settings.relay_backup);
        assert!(!merge_state(b, a).settings.relay_backup);
    }

    fn arb_machine() -> impl Strategy<Value = Machine> {
        ("[a-d]", "[a-z]{1,3}", 0u64..5, any::<bool>())
            .prop_map(|(k, n, u, d)| machine(&k, &n, u, d))
    }

    fn arb_answer() -> impl Strategy<Value = RememberedAnswer> {
        ("[ab]", "[XY]", 0u64..4, any::<bool>()).prop_map(|(a, k, u, d)| RememberedAnswer {
            agent: a,
            key_name: k,
            repo_id: "r".into(),
            updated: u,
            deleted: d,
            ..RememberedAnswer::default()
        })
    }

    fn arb_state() -> impl Strategy<Value = State> {
        (
            proptest::collection::vec(arb_machine(), 0..6),
            proptest::collection::vec(arb_answer(), 0..6),
        )
            .prop_map(|(machines, answers)| State {
                machines,
                answers,
                ..State::default()
            })
    }

    proptest! {
        #[test]
        fn merge_is_commutative(a in arb_state(), b in arb_state()) {
            prop_assert_eq!(merge_state(a.clone(), b.clone()), merge_state(b, a));
        }

        #[test]
        fn merge_is_associative_and_idempotent(a in arb_state(), b in arb_state(), c in arb_state()) {
            let ab_c = merge_state(merge_state(a.clone(), b.clone()), c.clone());
            let a_bc = merge_state(a.clone(), merge_state(b, c));
            prop_assert_eq!(&ab_c, &a_bc);
            prop_assert_eq!(merge_state(ab_c.clone(), ab_c.clone()), ab_c);
        }

        #[test]
        fn deleted_stays_deleted(a in arb_state(), b in arb_state()) {
            let m = merge_state(a.clone(), b.clone());
            // A tombstone newer than every live copy wins.
            for t in a.machines.iter().chain(b.machines.iter()).filter(|m| m.deleted) {
                let newest_live = a.machines.iter().chain(b.machines.iter())
                    .filter(|x| x.key == t.key && !x.deleted)
                    .map(|x| x.updated).max();
                if newest_live.is_none_or(|u| u < t.updated) {
                    prop_assert!(m.machines.iter().find(|x| x.key == t.key).unwrap().deleted);
                }
            }
        }
    }
}
