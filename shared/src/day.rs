//! Days and dates in the phone's local time. The phone passes its current UTC offset.

const MINUTE: i64 = 60_000;
const HOUR: i64 = 60 * MINUTE;
const DAY: i64 = 24 * HOUR;
/// A day ends at the latest 14 hours after its first approval.
pub const DAY_MAX_MS: u64 = 14 * HOUR as u64;

/// The end of a machine's day that began at `first_approval`: the next 02:00 local time or
/// 14 hours later, whichever is first.
#[uniffi::export]
pub fn day_end(first_approval: u64, utc_offset_secs: i32) -> u64 {
    let off = i64::from(utc_offset_secs) * 1000;
    let local = first_approval as i64 + off;
    let mut two = local.div_euclid(DAY) * DAY + 2 * HOUR;
    if local >= two {
        two += DAY;
    }
    let by_clock = (two - off) as u64;
    by_clock.min(first_approval + DAY_MAX_MS)
}

/// `YYYY-MM-DD` of a Unix ms time at a UTC offset.
#[uniffi::export]
pub fn local_date(time: u64, utc_offset_secs: i32) -> String {
    let days = (time as i64 + i64::from(utc_offset_secs) * 1000).div_euclid(DAY);
    let (y, m, d) = civil_from_days(days);
    format!("{y:04}-{m:02}-{d:02}")
}

/// `YYYY-MM` of a Unix ms time at a UTC offset.
pub fn local_month(time: u64, utc_offset_secs: i32) -> String {
    local_date(time, utc_offset_secs)[..7].to_owned()
}

/// Days since 1970-01-01 to (year, month, day); Howard Hinnant's algorithm.
fn civil_from_days(z: i64) -> (i64, u32, u32) {
    let z = z + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let m = if mp < 10 { mp + 3 } else { mp - 9 } as u32;
    (if m <= 2 { y + 1 } else { y }, m, d)
}

/// Days since 1970-01-01 of a `YYYY-MM-DD` date.
pub fn days_from_civil(date: &str) -> Option<i64> {
    let mut it = date.split('-');
    let y: i64 = it.next()?.parse().ok()?;
    let m: i64 = it.next()?.parse().ok()?;
    let d: i64 = it.next()?.parse().ok()?;
    if !(1..=12).contains(&m) || !(1..=31).contains(&d) {
        return None;
    }
    let y = if m <= 2 { y - 1 } else { y };
    let era = y.div_euclid(400);
    let yoe = y - era * 400;
    let mp = if m > 2 { m - 3 } else { m + 9 };
    let doy = (153 * mp + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    Some(era * 146_097 + doe - 719_468)
}

/// The date `days` after `date` (`YYYY-MM-DD`).
#[uniffi::export]
pub fn add_days(date: String, days: i64) -> String {
    match days_from_civil(&date) {
        Some(n) => {
            let (y, m, d) = civil_from_days(n + days);
            format!("{y:04}-{m:02}-{d:02}")
        }
        None => date,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // 2026-11-21T09:02:00Z
    const T: u64 = 1_795_251_720_000;

    #[test]
    fn dates() {
        assert_eq!(local_date(T, 0), "2026-11-21");
        assert_eq!(local_date(T, -10 * 3600), "2026-11-20");
        assert_eq!(local_date(0, 0), "1970-01-01");
        assert_eq!(add_days("2026-11-21".into(), 365), "2027-11-21");
        assert_eq!(add_days("2028-02-28".into(), 1), "2028-02-29");
        assert_eq!(local_month(T, 0), "2026-11");
    }

    #[test]
    fn day_ends_at_two_or_fourteen_hours() {
        // 09:02 UTC, offset 0: 14 h later (23:02) comes before 02:00.
        assert_eq!(day_end(T, 0), T + DAY_MAX_MS);
        // 15:00 local: 02:00 next day (11 h) comes first.
        let t15 = T + 6 * 3_600_000 - 2 * 60_000;
        let end = day_end(t15, 0);
        assert_eq!(local_date(end, 0), "2026-11-22");
        assert_eq!((end / 1000) % 86_400, 2 * 3600);
        // 01:00 local: the day ends at 02:00 the same night.
        let t1 = T - 8 * 3_600_000 - 2 * 60_000;
        assert_eq!(day_end(t1, 0) - t1, 3_600_000);
        // At UTC+2, 01:30 UTC is 03:30 local: next 02:00 local is 22.5 h away, so 14 h wins.
        let t = T - 7 * 3_600_000 - 32 * 60_000; // 01:30 UTC
        assert_eq!(day_end(t, 7200), t + DAY_MAX_MS);
        // At UTC-5, 05:00 UTC is 00:00 local: ends at 02:00 local.
        let t = T - 4 * 3_600_000 - 2 * 60_000; // 05:00 UTC
        assert_eq!(day_end(t, -5 * 3600) - t, 2 * 3_600_000);
    }

    #[test]
    fn exactly_two_oclock_starts_a_new_day() {
        let two = T - 7 * 3_600_000 - 2 * 60_000; // 02:00 UTC
        assert_eq!(day_end(two, 0), two + DAY_MAX_MS);
    }
}
