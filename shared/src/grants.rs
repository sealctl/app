//! Leaving a trusted place (SPEC.md 11.9): which machines to lock. A machine's allowance comes
//! from its latest `open` allowed for a session; when that was at a trusted place, the phone
//! leaving the place locks the machine, wherever its day began.
//!
//! The phone learns it is no longer inside a place from the exit event, and also when an exit
//! went missing: a fresh fix outside the place ([`places_left_by_fix`]), the geofences' state
//! after a restart, or location access no longer letting it notice leaving.

use sealctl_core::RequestKind;

use crate::day::day_end;
use crate::decide::day_active;
use crate::model::{DayRecord, GrantRecord, LocalState, LocationSample, TrustedPlace};
use crate::places::distance_m;

/// How old a fix may be and still say where the phone is now.
pub const FIX_FRESH_MS: u64 = 2 * 60_000;
/// How far past the phone's clock a fix may be dated (the two clocks differ a little).
pub const FIX_AHEAD_MS: u64 = 60_000;

/// Whether an answer sets the machine's allowance: an `open` allowed for the session (One tap's
/// "Allow for this session", or answered by itself). The machine takes its cap from that
/// reply's place; "Allow once" hands keys to one command and opens no session.
pub fn sets_allowance(kind: RequestKind, outcome: &str, allowed: bool) -> bool {
    allowed && kind == RequestKind::Open && matches!(outcome, "one_tap" | "automatic")
}

/// Records an allowance in `grants`: it replaces the machine's earlier one, unless that one is
/// newer (an answer the iOS extension gave, merged later). Allowances past their end are
/// dropped.
pub fn record_grant(
    grants: &mut Vec<GrantRecord>,
    machine: &str,
    place_id: Option<String>,
    at: u64,
    utc_offset_secs: i32,
    now: u64,
) {
    grants.retain(|g| g.ends > now);
    if grants.iter().any(|g| g.machine == machine && g.at > at) {
        return;
    }
    grants.retain(|g| g.machine != machine);
    grants.push(GrantRecord {
        machine: machine.to_owned(),
        place_id,
        at,
        ends: day_end(at, utc_offset_secs),
        locked: false,
    });
}

/// The allowances to lock now that the phone is not inside the places `left`: each machine's
/// latest session allowed at one of them, not locked yet and not ended. A place no longer
/// trusted locks nothing: its machines stay Open until their allowance ends (11.9).
///
/// A machine with no allowance recorded (allowed before this record was kept) is found by its
/// day, as before: a day that began at the place and is still running.
pub fn grants_left(
    grants: &[GrantRecord],
    days: &[DayRecord],
    places: &[TrustedPlace],
    left: &[String],
    now: u64,
    utc_offset_secs: i32,
) -> Vec<GrantRecord> {
    let counts = |id: &Option<String>| {
        id.as_ref()
            .is_some_and(|id| left.contains(id) && places.iter().any(|p| &p.id == id && !p.deleted))
    };
    let mut out: Vec<GrantRecord> = grants
        .iter()
        .filter(|g| !g.locked && now < g.ends && counts(&g.place_id))
        .cloned()
        .collect();
    for d in days {
        if counts(&d.place_id)
            && day_active(d, now, utc_offset_secs)
            && !grants.iter().any(|g| g.machine == d.machine)
        {
            out.push(GrantRecord {
                machine: d.machine.clone(),
                place_id: d.place_id.clone(),
                at: d.first_approval,
                ends: d.ends,
                locked: false,
            });
        }
    }
    out
}

/// [`grants_left`] on the phone's local records: the allowances to lock now that the phone is
/// not inside the places `left`. [`crate::store::Store::grants_left`] reads the same from the
/// database.
#[uniffi::export]
pub fn grants_to_lock(
    local: LocalState,
    places: Vec<TrustedPlace>,
    left: Vec<String>,
    now: u64,
    utc_offset_secs: i32,
) -> Vec<GrantRecord> {
    grants_left(
        &local.grants,
        &local.days,
        &places,
        &left,
        now,
        utc_offset_secs,
    )
}

/// Marks an allowance locked: the lock for it was sent. One allowed since (a newer `at`) stays
/// as it is; a machine found by its day gets a record, so the day locks it only once.
pub fn grant_locked(grants: &mut Vec<GrantRecord>, grant: GrantRecord) {
    match grants.iter_mut().find(|g| g.machine == grant.machine) {
        Some(g) if g.at == grant.at => g.locked = true,
        Some(_) => {}
        None => grants.push(GrantRecord {
            locked: true,
            ..grant
        }),
    }
}

/// The trusted places a fix shows the phone is outside: farther from the centre than the
/// radius plus the fix's accuracy, so a rough fix never says the phone left. Only a fresh fix
/// counts, dated within [`FIX_FRESH_MS`] before `now` (Unix ms, the phone's clock).
#[uniffi::export]
pub fn places_left_by_fix(places: Vec<TrustedPlace>, fix: LocationSample, now: u64) -> Vec<String> {
    let fresh = fix.time.saturating_add(FIX_FRESH_MS) >= now
        && fix.time <= now.saturating_add(FIX_AHEAD_MS);
    if !fresh || !fix.accuracy.is_finite() || !fix.lat.is_finite() || !fix.lon.is_finite() {
        return Vec::new();
    }
    let accuracy = fix.accuracy.max(0.0);
    places
        .into_iter()
        .filter(|p| !p.deleted && distance_m(p.lat, p.lon, fix.lat, fix.lon) > p.radius + accuracy)
        .map(|p| p.id)
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 2026-11-26T07:00:00Z.
    const T: u64 = 1_795_676_400_000;
    const MIN: u64 = 60_000;
    const H: u64 = 60 * MIN;

    fn place(id: &str, lat: f64, lon: f64) -> TrustedPlace {
        TrustedPlace {
            id: id.into(),
            name: id.into(),
            lat,
            lon,
            radius: 150.0,
            ..TrustedPlace::default()
        }
    }

    fn places() -> Vec<TrustedPlace> {
        vec![place("home", 50.45, 30.52), place("desk", 50.40, 30.60)]
    }

    fn fix(lat: f64, lon: f64, accuracy: f64, time: u64) -> LocationSample {
        LocationSample {
            lat,
            lon,
            accuracy,
            time,
        }
    }

    fn machines(g: &[GrantRecord]) -> Vec<&str> {
        let mut m: Vec<&str> = g.iter().map(|g| g.machine.as_str()).collect();
        m.sort();
        m
    }

    #[test]
    fn only_a_session_allowed_for_open_sets_the_allowance() {
        assert!(sets_allowance(RequestKind::Open, "one_tap", true));
        assert!(sets_allowance(RequestKind::Open, "automatic", true));
        assert!(!sets_allowance(RequestKind::Open, "once", true));
        assert!(!sets_allowance(RequestKind::Open, "denied", false));
        assert!(!sets_allowance(RequestKind::Open, "one_tap", false));
        assert!(!sets_allowance(RequestKind::Keys, "one_tap", true));
        assert!(!sets_allowance(RequestKind::Agent, "one_tap", true));
        assert!(!sets_allowance(RequestKind::Unseal, "confirmed", true));
    }

    #[test]
    fn the_latest_allowance_replaces_the_earlier_one_and_an_older_one_does_not() {
        let mut g = Vec::new();
        record_grant(&mut g, "mac", None, T, 0, T);
        record_grant(&mut g, "mac", Some("home".into()), T + H, 0, T + H);
        assert_eq!(g.len(), 1);
        assert_eq!(g[0].place_id.as_deref(), Some("home"));
        // The extension's answer from before, merged now, does not replace it.
        record_grant(&mut g, "mac", None, T + 30 * MIN, 0, T + 2 * H);
        assert_eq!(g[0].place_id.as_deref(), Some("home"));
        assert_eq!(g[0].at, T + H);
        // It lasts until the end of its day, 02:00 at UTC+0 here.
        assert_eq!(g[0].ends, day_end(T + H, 0));
        // Once that is past, the next answer drops it.
        let ends = g[0].ends;
        record_grant(&mut g, "pc", None, ends, 0, ends);
        assert_eq!(machines(&g), vec!["pc"]);
    }

    #[test]
    fn leaving_locks_the_machines_allowed_there_wherever_their_day_began() {
        let places = places();
        // The owner's day: the Mac's day began at 07:13 with no place, and it was allowed
        // again at Home at 08:00. The PC's day began at Home, but its latest session was
        // allowed at the desk. The laptop's only session was allowed with no place.
        let days = vec![
            DayRecord {
                machine: "mac".into(),
                first_approval: T + 13 * MIN,
                place_id: None,
                ends: day_end(T + 13 * MIN, 0),
            },
            DayRecord {
                machine: "pc".into(),
                first_approval: T,
                place_id: Some("home".into()),
                ends: day_end(T, 0),
            },
        ];
        let mut g = Vec::new();
        record_grant(&mut g, "mac", None, T + 13 * MIN, 0, T + 13 * MIN);
        record_grant(&mut g, "pc", Some("home".into()), T, 0, T);
        record_grant(&mut g, "laptop", None, T + 20 * MIN, 0, T + 20 * MIN);
        record_grant(&mut g, "mac", Some("home".into()), T + H, 0, T + H);
        record_grant(&mut g, "pc", Some("desk".into()), T + H, 0, T + H);
        let now = T + 2 * H;
        let left = grants_left(&g, &days, &places, &["home".into()], now, 0);
        assert_eq!(machines(&left), vec!["mac"]);
        // Leaving the desk locks the PC only.
        let left = grants_left(&g, &days, &places, &["desk".into()], now, 0);
        assert_eq!(machines(&left), vec!["pc"]);
        // Several machines allowed at Home are all locked.
        record_grant(&mut g, "laptop", Some("home".into()), now, 0, now);
        let left = grants_left(&g, &days, &places, &["home".into()], now, 0);
        assert_eq!(machines(&left), vec!["laptop", "mac"]);
        // Every trusted place at once (location can no longer notice leaving): every machine
        // allowed at one.
        let all: Vec<String> = places.iter().map(|p| p.id.clone()).collect();
        let left = grants_left(&g, &days, &places, &all, now, 0);
        assert_eq!(machines(&left), vec!["laptop", "mac", "pc"]);
    }

    #[test]
    fn a_lock_sent_is_not_sent_again_and_a_newer_allowance_still_counts() {
        let places = places();
        let mut g = Vec::new();
        record_grant(&mut g, "mac", Some("home".into()), T, 0, T);
        let left = grants_left(&g, &[], &places, &["home".into()], T + H, 0);
        assert_eq!(left.len(), 1);
        grant_locked(&mut g, left[0].clone());
        assert!(grants_left(&g, &[], &places, &["home".into()], T + H, 0).is_empty());
        // Opened at Home again later: leaving locks it again.
        record_grant(&mut g, "mac", Some("home".into()), T + 2 * H, 0, T + 2 * H);
        let again = grants_left(&g, &[], &places, &["home".into()], T + 3 * H, 0);
        assert_eq!(again.len(), 1);
        // A lock for the older one, sent while the newer was allowed, leaves the newer as it is.
        grant_locked(&mut g, left[0].clone());
        assert_eq!(
            grants_left(&g, &[], &places, &["home".into()], T + 3 * H, 0).len(),
            1
        );
    }

    #[test]
    fn an_allowance_past_its_day_is_not_locked() {
        let places = places();
        let mut g = Vec::new();
        record_grant(&mut g, "mac", Some("home".into()), T, 0, T);
        let ends = g[0].ends;
        assert_eq!(
            grants_left(&g, &[], &places, &["home".into()], ends - 1, 0).len(),
            1
        );
        assert!(grants_left(&g, &[], &places, &["home".into()], ends, 0).is_empty());
    }

    #[test]
    fn a_removed_place_locks_nothing_its_machines_stay_open_until_their_allowance_ends() {
        let mut places = places();
        let mut g = Vec::new();
        record_grant(&mut g, "mac", Some("home".into()), T, 0, T);
        places[0].deleted = true;
        assert!(grants_left(&g, &[], &places, &["home".into()], T + H, 0).is_empty());
        // Neither does a place this phone never had.
        assert!(grants_left(&g, &[], &[], &["home".into()], T + H, 0).is_empty());
        // A fix far away from it says nothing about it either.
        let away = places_left_by_fix(places.clone(), fix(50.0, 30.0, 10.0, T), T);
        assert!(!away.contains(&"home".to_string()));
    }

    #[test]
    fn a_day_begun_at_the_place_before_allowances_were_kept_still_locks_once() {
        let places = places();
        // Recorded by an earlier version: a day at Home, no allowance.
        let days = vec![DayRecord {
            machine: "mac".into(),
            first_approval: T,
            place_id: Some("home".into()),
            ends: day_end(T, 0),
        }];
        let mut g = Vec::new();
        let left = grants_left(&g, &days, &places, &["home".into()], T + H, 0);
        assert_eq!(machines(&left), vec!["mac"]);
        grant_locked(&mut g, left[0].clone());
        assert!(grants_left(&g, &days, &places, &["home".into()], T + H, 0).is_empty());
        // A day that ended locks nothing.
        let g = Vec::new();
        assert!(grants_left(&g, &days, &places, &["home".into()], day_end(T, 0), 0).is_empty());
        // Once the machine has an allowance elsewhere, its day at Home no longer counts.
        let mut g = Vec::new();
        record_grant(&mut g, "mac", None, T + H, 0, T + H);
        assert!(grants_left(&g, &days, &places, &["home".into()], T + 2 * H, 0).is_empty());
    }

    #[test]
    fn a_fresh_fix_clearly_outside_a_place_says_the_phone_left_it() {
        let now = T;
        // About 1.1 km north of Home, 10 m accuracy: outside Home and the desk.
        let far = fix(50.46, 30.52, 10.0, now - 30_000);
        let mut out = places_left_by_fix(places(), far, now);
        out.sort();
        assert_eq!(out, vec!["desk".to_string(), "home".to_string()]);
        // Inside Home: outside the desk only.
        let home = fix(50.4505, 30.52, 10.0, now);
        assert_eq!(
            places_left_by_fix(places(), home, now),
            vec!["desk".to_string()]
        );
        // 200 m from Home's centre with 100 m accuracy could still be inside: not left.
        let edge = fix(50.45 + 200.0 / 111_195.0, 30.52, 100.0, now);
        assert!(!places_left_by_fix(places(), edge, now).contains(&"home".to_string()));
        // The same spot with 20 m accuracy is outside.
        let edge = fix(50.45 + 200.0 / 111_195.0, 30.52, 20.0, now);
        assert!(places_left_by_fix(places(), edge, now).contains(&"home".to_string()));
        // A stale fix, one dated far ahead, or a broken one says nothing.
        let stale = fix(50.46, 30.52, 10.0, now - FIX_FRESH_MS - 1);
        assert!(places_left_by_fix(places(), stale, now).is_empty());
        let ahead = fix(50.46, 30.52, 10.0, now + FIX_AHEAD_MS + 1);
        assert!(places_left_by_fix(places(), ahead, now).is_empty());
        let broken = fix(50.46, 30.52, f64::NAN, now);
        assert!(places_left_by_fix(places(), broken, now).is_empty());
    }
}
