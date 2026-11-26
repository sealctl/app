//! Level 3 actions on the phone and their delay (SPEC.md 11.23): where a delayed action stands
//! at a given time, and which record a start button shows instead of starting another.
//!
//! An action on the phone (show the words, delete the relay data, leave) waits until
//! `release_at`, can then be finished until `expires` (the relay keeps the record that long),
//! and after that can only be started again. Both apps read the phase from here, so a screen
//! that is open at `release_at` turns ready by itself, and a record whose window closed while
//! the app was away reads as expired before the relay's list is fetched again.

use crate::model::DelayedAction;

/// The kind of a phone-only record another install started: the relay's record carries no kind.
pub const OTHER_DEVICE: &str = "unknown";

/// Where a delayed action stands (SPEC.md 11.23 Delay).
#[derive(uniffi::Enum, Debug, Clone, Copy, PartialEq, Eq)]
pub enum DelayPhase {
    /// Counting down to `release_at`.
    Waiting,
    /// Past `release_at` and before `expires`: an action on the phone can be finished.
    Ready,
    /// Past `expires`, or the relay no longer has it: it can only be started again.
    Expired,
    /// Cancelled, here or elsewhere.
    Cancelled,
    /// Finished on the phone, or, for a machine's `unseal --all`, its wait is over.
    Finished,
}

/// Where `action` stands at `now` (Unix ms). A machine's record (`unseal --all`) needs nothing
/// from the phone when its wait ends, so it is `Finished` from `release_at` on.
#[uniffi::export]
pub fn delay_phase(action: &DelayedAction, now: u64) -> DelayPhase {
    match action.state.as_str() {
        "cancelled" => DelayPhase::Cancelled,
        "finished" => DelayPhase::Finished,
        "gone" | "expired" => DelayPhase::Expired,
        _ if now < action.release_at => DelayPhase::Waiting,
        _ if action.machine.is_some() => DelayPhase::Finished,
        _ if now < action.expires => DelayPhase::Ready,
        _ => DelayPhase::Expired,
    }
}

/// The phone-only action of kind `what` that is still waiting or ready at `now`, the newest
/// when there are several. A start button of that kind shows it instead of starting another,
/// and with `what` = [`OTHER_DEVICE`] it finds one another install started (SPEC.md 11.23).
#[uniffi::export]
pub fn running_phone_action(
    delayed: Vec<DelayedAction>,
    what: String,
    now: u64,
) -> Option<DelayedAction> {
    delayed
        .into_iter()
        .filter(|d| d.machine.is_none() && d.what == what)
        .filter(|d| matches!(delay_phase(d, now), DelayPhase::Waiting | DelayPhase::Ready))
        .max_by_key(|d| (d.release_at, d.started))
}

#[cfg(test)]
mod tests {
    use super::*;

    const RELEASE: u64 = 10_000_000;
    const EXPIRES: u64 = RELEASE + 3_600_000;

    fn action(id: &str, what: &str, state: &str, release_at: u64) -> DelayedAction {
        DelayedAction {
            id: id.into(),
            what: what.into(),
            machine: None,
            release_at,
            expires: release_at + 3_600_000,
            state: state.into(),
            cancelled_by: None,
            started: release_at - 7_200_000,
        }
    }

    #[test]
    fn a_phone_action_waits_then_is_ready_until_it_expires() {
        let d = action("a", "words", "waiting", RELEASE);
        assert_eq!(delay_phase(&d, RELEASE - 1), DelayPhase::Waiting);
        // Ready at release_at without the relay's list saying so: a screen open then turns ready.
        assert_eq!(delay_phase(&d, RELEASE), DelayPhase::Ready);
        assert_eq!(delay_phase(&d, EXPIRES - 1), DelayPhase::Ready);
        assert_eq!(delay_phase(&d, EXPIRES), DelayPhase::Expired);
        // The relay's list says released: the same.
        let r = action("a", "words", "released", RELEASE);
        assert_eq!(delay_phase(&r, RELEASE + 1), DelayPhase::Ready);
        assert_eq!(delay_phase(&r, EXPIRES + 1), DelayPhase::Expired);
    }

    #[test]
    fn ended_states_do_not_depend_on_the_time() {
        for now in [0, RELEASE, EXPIRES + 1] {
            assert_eq!(
                delay_phase(&action("a", "words", "cancelled", RELEASE), now),
                DelayPhase::Cancelled
            );
            assert_eq!(
                delay_phase(&action("a", "words", "finished", RELEASE), now),
                DelayPhase::Finished
            );
            assert_eq!(
                delay_phase(&action("a", "words", "gone", RELEASE), now),
                DelayPhase::Expired
            );
            assert_eq!(
                delay_phase(&action("a", "words", "expired", RELEASE), now),
                DelayPhase::Expired
            );
        }
    }

    #[test]
    fn a_machine_record_needs_nothing_from_the_phone_after_its_wait() {
        let mut d = action("a", "unseal_all", "waiting", RELEASE);
        d.machine = Some("m1".into());
        assert_eq!(delay_phase(&d, RELEASE - 1), DelayPhase::Waiting);
        assert_eq!(delay_phase(&d, RELEASE), DelayPhase::Finished);
        d.state = "released".into();
        assert_eq!(delay_phase(&d, EXPIRES + 1), DelayPhase::Finished);
    }

    #[test]
    fn the_running_action_of_a_kind_is_the_newest_waiting_or_ready_one() {
        let list = vec![
            action("old", "words", "waiting", RELEASE - 60_000),
            action("new", "words", "waiting", RELEASE),
            action("cancelled", "words", "cancelled", RELEASE + 60_000),
            action("delete", "delete", "waiting", RELEASE + 120_000),
        ];
        let id = |now| running_phone_action(list.clone(), "words".into(), now).map(|d| d.id);
        assert_eq!(id(RELEASE - 10).as_deref(), Some("new"));
        assert_eq!(id(RELEASE + 10).as_deref(), Some("new"));
        // Both past their window: none runs, a start makes a new one.
        assert_eq!(id(EXPIRES + 1), None);
        assert_eq!(
            running_phone_action(list.clone(), "leave".into(), RELEASE),
            None
        );
        assert_eq!(
            running_phone_action(list, "delete".into(), RELEASE)
                .map(|d| d.id)
                .as_deref(),
            Some("delete")
        );
    }

    #[test]
    fn ended_records_and_machine_records_do_not_run() {
        let mut m = action("m", "words", "waiting", RELEASE);
        m.machine = Some("m1".into());
        let list = vec![
            action("f", "words", "finished", RELEASE),
            action("g", "words", "gone", RELEASE),
            action("c", "words", "cancelled", RELEASE),
            m,
        ];
        assert_eq!(
            running_phone_action(list, "words".into(), RELEASE - 10),
            None
        );
    }

    #[test]
    fn another_installs_action_is_found_by_its_unknown_kind() {
        let list = vec![
            action("x", OTHER_DEVICE, "waiting", RELEASE),
            action("w", "words", "cancelled", RELEASE),
        ];
        assert_eq!(
            running_phone_action(list.clone(), OTHER_DEVICE.into(), RELEASE - 10)
                .map(|d| d.id)
                .as_deref(),
            Some("x")
        );
        assert_eq!(
            running_phone_action(list, "words".into(), RELEASE - 10),
            None
        );
    }
}
