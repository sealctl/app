//! How the phone shows an Open machine's session (SPEC.md 11.8), from its last status: "active"
//! while the machine works, else a countdown to when it locks. A machine whose CLI sends no idle
//! time is counted down the same way.
//!
//! [`machine_session`] depends on the status only, so the apps read it once per status and
//! compare the times it gives with their clock each second ([`MachineSession`]).

use crate::model::SessionStatus;

/// A status whose `idle` is under this many seconds says the machine was active
/// (protocol.md, Machine status and messages: active and idle).
pub const ACTIVE_SECS: u64 = 120;

/// How long past those 2 minutes the phone still shows "active". A machine that stays active
/// says so again once they are over, and one that went idle says that, both at its next
/// 15-second sample; this minute covers the sample and the way to the phone. Without a status
/// (asleep, offline) the phone then counts the idle time on by itself.
pub const ACTIVE_GRACE_SECS: u64 = 60;

/// An Open machine's session as the Machines list shows it, from its last status. At a time
/// `now` (Unix ms) the machine is:
///
/// - not Open any more when `now >= locks_at` ("Locked · last report 3 h ago");
/// - active while `now < active_until` ("Open · active");
/// - else Open with `locks_at - now` left, counted down in whole minutes ("Open · locks in 3 h
///   47 min"), also without `last_work` (a CLI that sends no idle time).
#[derive(uniffi::Record, Debug, Clone, Default, PartialEq, Eq)]
pub struct MachineSession {
    /// The last status said Open.
    pub open: bool,
    /// When it locks unless more work comes, Unix ms: the report time plus `left`, capped by
    /// the hard stop.
    pub locks_at: u64,
    /// Its last work moment, Unix ms (the report time minus `idle`); `None` when its CLI does
    /// not send the idle time.
    pub last_work: Option<u64>,
    /// Until when it is shown active, Unix ms; `None` when the last status said idle (or had
    /// no idle time).
    pub active_until: Option<u64>,
    /// Its idle allowance, seconds, when its CLI sends it.
    pub allowance_secs: Option<u64>,
}

/// The session of a machine whose last status is `status`.
#[uniffi::export]
pub fn machine_session(status: SessionStatus) -> MachineSession {
    if status.session != "open" {
        return MachineSession::default();
    }
    let reported = status.reported_at;
    let deadline = reported.saturating_add(status.left.unwrap_or(0).saturating_mul(1000));
    let locks_at = status.stop.map_or(deadline, |stop| deadline.min(stop));
    let last_work = status
        .idle
        .map(|i| reported.saturating_sub(i.saturating_mul(1000)));
    let active_until = last_work
        .filter(|_| status.idle.is_some_and(|i| i < ACTIVE_SECS))
        .map(|w| {
            w.saturating_add((ACTIVE_SECS + ACTIVE_GRACE_SECS) * 1000)
                .min(locks_at)
        });
    MachineSession {
        open: true,
        locks_at,
        last_work,
        active_until,
        allowance_secs: status.allow,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const T: u64 = 1_800_000_000_000;
    const MIN: u64 = 60_000;

    fn open(left: u64, idle: Option<u64>, allow: Option<u64>, stop: Option<u64>) -> SessionStatus {
        SessionStatus {
            session: "open".into(),
            left: Some(left),
            idle,
            allow,
            stop,
            reported_at: T,
            ..SessionStatus::default()
        }
    }

    #[test]
    fn a_machine_at_work_is_active_without_a_countdown() {
        let s = machine_session(open(14_390, Some(10), Some(14_400), None));
        assert!(s.open);
        assert_eq!(s.last_work, Some(T - 10_000));
        // the machine's next status is due 2 minutes after its last work; until it comes,
        // "active" stays a minute longer
        assert_eq!(s.active_until, Some(T - 10_000 + 3 * MIN));
        assert_eq!(s.allowance_secs, Some(14_400));
        assert_eq!(s.locks_at, T + 14_390_000);
        // just under 2 minutes of no work is still active
        let s = machine_session(open(14_281, Some(119), Some(14_400), None));
        assert_eq!(s.active_until, Some(T - 119_000 + 3 * MIN));
    }

    #[test]
    fn an_idle_machine_has_its_last_work_and_when_it_locks() {
        // idle 12 minutes when it reported, 4 h allowance
        let s = machine_session(open(
            13_680,
            Some(720),
            Some(14_400),
            Some(T + 10 * 60 * MIN),
        ));
        assert!(s.open);
        assert_eq!(s.active_until, None);
        assert_eq!(s.last_work, Some(T - 12 * MIN));
        assert_eq!(s.locks_at, T + 13_680_000);
        // 2 minutes is idle
        let s = machine_session(open(14_280, Some(120), Some(14_400), None));
        assert_eq!(s.active_until, None);
    }

    #[test]
    fn the_hard_stop_comes_first_when_it_is_sooner() {
        let stop = T + 30 * MIN;
        let s = machine_session(open(13_680, Some(720), Some(14_400), Some(stop)));
        assert_eq!(s.locks_at, stop);
        // nor is it active past the hard stop
        let stop = T + MIN;
        let s = machine_session(open(14_390, Some(10), Some(14_400), Some(stop)));
        assert_eq!((s.locks_at, s.active_until), (stop, Some(stop)));
    }

    #[test]
    fn a_cli_without_idle_counts_down_as_before() {
        let s = machine_session(open(600, None, None, None));
        assert!(s.open);
        assert_eq!(
            (s.last_work, s.active_until, s.allowance_secs),
            (None, None, None)
        );
        assert_eq!(s.locks_at, T + 600_000);
    }

    #[test]
    fn locked_and_waiting_are_not_open() {
        for state in ["locked", "waiting", ""] {
            let st = SessionStatus {
                session: state.into(),
                left: Some(600),
                idle: Some(0),
                reported_at: T,
                ..SessionStatus::default()
            };
            assert_eq!(machine_session(st), MachineSession::default(), "{state}");
        }
    }
}
