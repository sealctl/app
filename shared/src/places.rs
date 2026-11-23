//! Learning places (SPEC.md 11.9): a sample joins a candidate within 100 m of its centre when
//! its accuracy is 100 m or better; a candidate with samples on 3 different days is offered.

use crate::day::{days_from_civil, local_date};
use crate::model::{LocationSample, PlaceCandidate, TrustedPlace};

/// Join radius, metres.
pub const JOIN_RADIUS_M: f64 = 100.0;
/// Worst accuracy a sample may have, metres.
pub const MAX_ACCURACY_M: f64 = 100.0;
/// Radius of a trusted place, metres.
pub const PLACE_RADIUS_M: f64 = 150.0;
/// Days of samples before a candidate is offered.
pub const DAYS_TO_OFFER: usize = 3;
/// Samples older than this are dropped, days.
pub const SAMPLE_DAYS: i64 = 30;
/// Most trusted places.
pub const MAX_PLACES: usize = 10;

/// Great-circle distance in metres.
#[uniffi::export]
pub fn distance_m(lat1: f64, lon1: f64, lat2: f64, lon2: f64) -> f64 {
    let r = 6_371_000.0_f64;
    let (p1, p2) = (lat1.to_radians(), lat2.to_radians());
    let dp = (lat2 - lat1).to_radians();
    let dl = (lon2 - lon1).to_radians();
    let a = (dp / 2.0).sin().powi(2) + p1.cos() * p2.cos() * (dl / 2.0).sin().powi(2);
    2.0 * r * a.sqrt().asin()
}

/// The trusted place a point is inside, if any.
#[uniffi::export]
pub fn place_at(places: Vec<TrustedPlace>, lat: f64, lon: f64) -> Option<TrustedPlace> {
    places
        .into_iter()
        .filter(|p| !p.deleted)
        .find(|p| distance_m(p.lat, p.lon, lat, lon) <= p.radius)
}

/// The result of one sample.
#[derive(uniffi::Record, Debug, Clone, PartialEq)]
pub struct PlaceSampleResult {
    /// Candidates after the sample.
    pub candidates: Vec<PlaceCandidate>,
    /// A candidate that just reached 3 days and was not offered before.
    pub ready: Option<PlaceCandidate>,
}

/// Adds one location sample. `new_id` names a new candidate if one is made.
pub fn place_sample(
    mut candidates: Vec<PlaceCandidate>,
    places: &[TrustedPlace],
    sample: LocationSample,
    utc_offset_secs: i32,
    new_id: String,
) -> PlaceSampleResult {
    let today = local_date(sample.time, utc_offset_secs);
    let today_n = days_from_civil(&today).unwrap_or(0);
    let recent = |date: &str| today_n - days_from_civil(date).unwrap_or(0) < SAMPLE_DAYS;
    for c in &mut candidates {
        // Each sample's day is the local date it was taken on, kept in `days`: dating old
        // samples again with today's UTC offset (after a change of daylight saving time or
        // of time zone) could split one morning into two.
        if c.days.is_empty() {
            c.days = distinct_days(&c.samples, utc_offset_secs);
        }
        c.samples
            .retain(|s| recent(&local_date(s.time, utc_offset_secs)));
        c.days.retain(|d| recent(d));
        if c.samples.is_empty() {
            c.days.clear();
        }
        recentre(c);
    }
    candidates.retain(|c| c.suppressed || !c.samples.is_empty());

    let inside_place = places
        .iter()
        .any(|p| !p.deleted && distance_m(p.lat, p.lon, sample.lat, sample.lon) <= p.radius);
    if sample.accuracy > MAX_ACCURACY_M || inside_place {
        return PlaceSampleResult {
            candidates,
            ready: None,
        };
    }
    let near = candidates
        .iter_mut()
        .filter(|c| distance_m(c.lat, c.lon, sample.lat, sample.lon) <= JOIN_RADIUS_M)
        .min_by(|a, b| {
            distance_m(a.lat, a.lon, sample.lat, sample.lon)
                .total_cmp(&distance_m(b.lat, b.lon, sample.lat, sample.lon))
        });
    let id = match near {
        Some(c) => {
            if c.suppressed {
                return PlaceSampleResult {
                    candidates,
                    ready: None,
                };
            }
            c.samples.push(sample);
            c.days.push(today.clone());
            c.days.sort();
            c.days.dedup();
            recentre(c);
            c.id.clone()
        }
        None => {
            let c = PlaceCandidate {
                id: new_id,
                lat: sample.lat,
                lon: sample.lon,
                samples: vec![sample],
                days: vec![today],
                ..PlaceCandidate::default()
            };
            let id = c.id.clone();
            candidates.push(c);
            id
        }
    };
    // With every place slot taken there is nothing to offer; the candidate stays unasked, so
    // it is offered once a place is removed.
    let room = places.iter().filter(|p| !p.deleted).count() < MAX_PLACES;
    let ready = candidates
        .iter_mut()
        .find(|c| room && c.id == id && !c.asked && !c.suppressed && c.days.len() >= DAYS_TO_OFFER)
        .map(|c| {
            c.asked = true;
            c.clone()
        });
    PlaceSampleResult { candidates, ready }
}

fn distinct_days(samples: &[LocationSample], off: i32) -> Vec<String> {
    let mut days: Vec<String> = samples.iter().map(|s| local_date(s.time, off)).collect();
    days.sort();
    days.dedup();
    days
}

fn recentre(c: &mut PlaceCandidate) {
    if c.samples.is_empty() {
        return;
    }
    let n = c.samples.len() as f64;
    c.lat = c.samples.iter().map(|s| s.lat).sum::<f64>() / n;
    c.lon = c.samples.iter().map(|s| s.lon).sum::<f64>() / n;
}

#[cfg(test)]
mod tests {
    use super::*;

    const DAY: u64 = 86_400_000;
    const T: u64 = 1_795_251_720_000;

    fn s(lat: f64, lon: f64, acc: f64, t: u64) -> LocationSample {
        LocationSample {
            lat,
            lon,
            accuracy: acc,
            time: t,
        }
    }

    #[test]
    fn distance() {
        let d = distance_m(52.2297, 21.0122, 52.2297, 21.0137);
        assert!((d - 102.0).abs() < 2.0, "{d}");
    }

    #[test]
    fn three_mornings_make_a_candidate() {
        let mut c = Vec::new();
        let mut ready = None;
        for (n, t) in [T, T + 3_600_000, T + DAY, T + 2 * DAY]
            .into_iter()
            .enumerate()
        {
            let r = place_sample(
                c,
                &[],
                s(52.2297, 21.0122 + n as f64 * 0.0001, 20.0, t),
                0,
                format!("c{n}"),
            );
            c = r.candidates;
            if r.ready.is_some() {
                ready = r.ready;
            }
        }
        assert_eq!(c.len(), 1);
        let ready = ready.expect("offered on the third day");
        assert_eq!(ready.days, vec!["2026-11-21", "2026-11-22", "2026-11-23"]);
        // Offered once only.
        let r = place_sample(
            c,
            &[],
            s(52.2297, 21.0122, 20.0, T + 3 * DAY),
            0,
            "x".into(),
        );
        assert!(r.ready.is_none());
    }

    #[test]
    fn a_change_of_utc_offset_does_not_add_mornings() {
        // 2026-11-21T00:00:00Z.
        let midnight = 1_795_219_200_000;
        let h = 3_600_000;
        let at = |t| s(52.2297, 21.0122, 20.0, t);
        // Two first approvals on 2026-11-21 at UTC+1: 00:30 and 23:45.
        let r = place_sample(Vec::new(), &[], at(midnight - h / 2), 3600, "a".into());
        let r = place_sample(
            r.candidates,
            &[],
            at(midnight + 22 * h + 45 * 60_000),
            3600,
            "b".into(),
        );
        assert_eq!(r.candidates[0].days, vec!["2026-11-21"]);
        // Two days later the phone is at UTC+2 (daylight saving, or travel): still two days.
        let r = place_sample(r.candidates, &[], at(midnight + 55 * h), 7200, "c".into());
        assert_eq!(r.candidates[0].days, vec!["2026-11-21", "2026-11-23"]);
        assert!(r.ready.is_none());
    }

    #[test]
    fn no_offer_while_every_place_slot_is_taken() {
        let full: Vec<TrustedPlace> = (0..MAX_PLACES)
            .map(|n| TrustedPlace {
                id: format!("p{n}"),
                lat: 10.0 + n as f64,
                lon: 10.0,
                radius: PLACE_RADIUS_M,
                ..TrustedPlace::default()
            })
            .collect();
        let mut c = Vec::new();
        for (n, t) in [T, T + DAY, T + 2 * DAY].into_iter().enumerate() {
            let r = place_sample(c, &full, s(52.2297, 21.0122, 20.0, t), 0, format!("c{n}"));
            assert!(r.ready.is_none());
            c = r.candidates;
        }
        assert!(!c[0].asked);
        // Offered once a place is removed.
        let mut fewer = full;
        fewer[0].deleted = true;
        let r = place_sample(
            c,
            &fewer,
            s(52.2297, 21.0122, 20.0, T + 3 * DAY),
            0,
            "x".into(),
        );
        assert!(r.ready.is_some());
    }

    #[test]
    fn inaccurate_far_and_suppressed_samples() {
        let r = place_sample(Vec::new(), &[], s(1.0, 1.0, 150.0, T), 0, "a".into());
        assert!(r.candidates.is_empty());
        let r = place_sample(Vec::new(), &[], s(1.0, 1.0, 10.0, T), 0, "a".into());
        let r = place_sample(
            r.candidates,
            &[],
            s(1.01, 1.0, 10.0, T + DAY),
            0,
            "b".into(),
        );
        assert_eq!(r.candidates.len(), 2);
        let mut c = r.candidates;
        c[0].suppressed = true;
        let r = place_sample(c, &[], s(1.0, 1.0, 10.0, T + 2 * DAY), 0, "c".into());
        let a = r.candidates.iter().find(|c| c.id == "a").unwrap();
        assert_eq!(a.samples.len(), 1);
    }

    #[test]
    fn samples_inside_a_place_and_old_samples() {
        let place = TrustedPlace {
            id: "p".into(),
            lat: 1.0,
            lon: 1.0,
            radius: PLACE_RADIUS_M,
            ..TrustedPlace::default()
        };
        let r = place_sample(
            Vec::new(),
            std::slice::from_ref(&place),
            s(1.0, 1.0, 10.0, T),
            0,
            "a".into(),
        );
        assert!(r.candidates.is_empty());
        assert_eq!(
            place_at(vec![place], 1.0005, 1.0).map(|p| p.id),
            Some("p".into())
        );
        let r = place_sample(Vec::new(), &[], s(2.0, 2.0, 10.0, T), 0, "a".into());
        let r = place_sample(
            r.candidates,
            &[],
            s(3.0, 3.0, 10.0, T + 31 * DAY),
            0,
            "b".into(),
        );
        assert_eq!(r.candidates.len(), 1);
        assert_eq!(r.candidates[0].id, "b");
    }
}
