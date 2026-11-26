//! The phone's clock, corrected against the relay (SPEC.md 8.1).
//!
//! Every security window (a hold, the two hours of a place added by hand, the level 3 delay
//! and a plan's window) is counted on this clock, not on the system clock, which the person
//! holding the phone can set. The relay's time is taken when the phone reaches it (`GET
//! /v1/health`, a `401 clock_skew`) and carried forward on the phone's since-boot clock,
//! which counts sleep and which no setting moves. While that is fresh the clock is the
//! relay's; when it is stale or unknown, the later of the system clock and the last-known
//! relay time, so a wait never ends early because the clock was set back.

use serde::{Deserialize, Serialize};

use crate::model::TrustedPlace;

/// How long a relay time carried on the since-boot clock stays fresh.
pub const CLOCK_FRESH_MS: u64 = 24 * 3_600_000;

/// The relay accepts a signed time this far either side of its own (Relay API, Signing).
pub const SIGNED_WINDOW_MS: u64 = 5 * 60 * 1000;

/// A signed call's time is whole seconds; it may lag the clock by up to this much.
const SIGNED_SLACK_MS: u64 = 2_000;

/// The last relay time the phone learned (stored as the `clock` doc; the iOS app copies it to
/// its extension's snapshot).
#[derive(uniffi::Record, Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct RelayClock {
    /// The relay's time then, Unix ms; 0 when never learned.
    pub relay: u64,
    /// The since-boot clock then, ms.
    pub boot: u64,
    /// The boot it was learned in ("" when the phone does not tell).
    pub boot_id: String,
    /// A signed call the relay accepted disagreed with it by more than the signature window.
    pub distrusted: bool,
}

/// The since-boot clock now.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Boot {
    /// Milliseconds since boot, counting sleep.
    pub ms: u64,
    /// This boot's id ("" when unknown).
    pub id: String,
}

/// The corrected clock now.
#[derive(uniffi::Record, Debug, Clone, Copy, PartialEq, Eq)]
pub struct ClockNow {
    /// Unix ms.
    pub now: u64,
    /// The relay's time, learned in this boot within the last 24 hours, with no signed call
    /// against it. When false the clock is the later of the system clock and the last-known
    /// relay time, and a place added by hand does not lift the level 3 delay.
    pub fresh: bool,
}

impl RelayClock {
    /// The relay's time `relay` (Unix ms), learned at `boot`.
    pub fn learned(relay: u64, boot: &Boot) -> Self {
        Self {
            relay,
            boot: boot.ms,
            boot_id: boot.id.clone(),
            distrusted: false,
        }
    }

    /// Same boot: the since-boot clock has not restarted and the boot ids match. An empty id
    /// matches nothing: without a boot id a reboot followed by a longer uptime would look
    /// like the same boot, so the time is not carried and the clock is stale (fails closed).
    fn same_boot(&self, boot: &Boot) -> bool {
        boot.ms >= self.boot && !self.boot_id.is_empty() && self.boot_id == boot.id
    }

    /// The relay's time carried forward: on the since-boot clock in the same boot, else the
    /// relay time as last learned.
    fn carried(&self, boot: &Boot) -> u64 {
        if self.same_boot(boot) {
            self.relay.saturating_add(boot.ms - self.boot)
        } else {
            self.relay
        }
    }

    /// The clock now, given the system clock and the since-boot clock.
    pub fn now(&self, system: u64, boot: &Boot) -> ClockNow {
        if self.relay == 0 {
            return ClockNow {
                now: system,
                fresh: false,
            };
        }
        let carried = self.carried(boot);
        let fresh =
            !self.distrusted && self.same_boot(boot) && boot.ms - self.boot <= CLOCK_FRESH_MS;
        ClockNow {
            now: if fresh { carried } else { carried.max(system) },
            fresh,
        }
    }

    /// A signed call at `signed` (Unix ms, the phone's `Sealctl-Time`) was accepted, so the
    /// relay's clock is within the signature window of it. A fresh clock that disagrees by
    /// more is no longer trusted. Returns whether this changed anything.
    pub fn signed_accepted(&mut self, signed: u64, system: u64, boot: &Boot) -> bool {
        let now = self.now(system, boot);
        if !now.fresh || now.now.abs_diff(signed) <= SIGNED_WINDOW_MS + SIGNED_SLACK_MS {
            return false;
        }
        self.distrusted = true;
        true
    }
}

/// The clock now by `clock`, on this phone's system and since-boot clocks: for the iOS
/// extension, which reads the app's snapshot rather than the store.
#[uniffi::export]
pub fn relay_clock_now(clock: RelayClock) -> ClockNow {
    clock.now(system_ms(), &boot_now())
}

/// The relay's time `relay_ms` (Unix ms), learned now.
#[uniffi::export]
pub fn relay_clock_learned(relay_ms: u64) -> RelayClock {
    RelayClock::learned(relay_ms, &boot_now())
}

/// Whether a trusted place lifts the level 3 delay at `now` ([`crate::decide::place_settled`]
/// on the corrected clock). A place added by hand without an announcement never does while the
/// clock is stale: its two hours can't be counted on a clock the person may have set. An
/// announced place needs no clock: the relay confirmed its two hours.
#[uniffi::export]
pub fn place_settled_at(place: TrustedPlace, now: ClockNow) -> bool {
    (now.fresh || !place.manual || place.trust_id.is_some())
        && crate::decide::place_settled(place, now.now)
}

/// The system clock, Unix ms.
pub fn system_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| d.as_millis() as u64)
}

/// The since-boot clock of this phone, counting sleep: `CLOCK_BOOTTIME` on Android and Linux,
/// `CLOCK_MONOTONIC` on Apple platforms (which counts sleep there); and the boot's id.
pub fn boot_now() -> Boot {
    Boot {
        ms: boot_ms(),
        id: boot_or_process_id(boot_id()),
    }
}

/// The boot's id, or when the system gives none (an app that can't read it), an id of this
/// process. A relay time learned by an earlier process then never counts as this boot's: the
/// clock is stale until the relay's time is learned again in this process, which the app
/// does on launch and foreground (SPEC.md 8.1). The system clock is not used to tell boots
/// apart: it is the clock that can be set.
fn boot_or_process_id(boot: String) -> String {
    if !boot.is_empty() {
        return boot;
    }
    static PROCESS: std::sync::OnceLock<String> = std::sync::OnceLock::new();
    PROCESS
        .get_or_init(|| format!("process-{}-{}", std::process::id(), boot_ms()))
        .clone()
}

#[cfg(any(target_os = "android", target_os = "linux"))]
const BOOT_CLOCK: libc::clockid_t = libc::CLOCK_BOOTTIME;
#[cfg(not(any(target_os = "android", target_os = "linux")))]
const BOOT_CLOCK: libc::clockid_t = libc::CLOCK_MONOTONIC;

fn boot_ms() -> u64 {
    let mut ts = libc::timespec {
        tv_sec: 0,
        tv_nsec: 0,
    };
    // SAFETY: `ts` is a valid, writable timespec for the call.
    if unsafe { libc::clock_gettime(BOOT_CLOCK, &mut ts) } != 0 {
        return 0;
    }
    (ts.tv_sec as u64).saturating_mul(1000) + (ts.tv_nsec as u64) / 1_000_000
}

#[cfg(any(target_os = "android", target_os = "linux"))]
fn boot_id() -> String {
    std::fs::read_to_string("/proc/sys/kernel/random/boot_id")
        .map(|s| s.trim().to_owned())
        .unwrap_or_default()
}

#[cfg(any(target_os = "ios", target_os = "macos"))]
fn boot_id() -> String {
    let mut buf = [0u8; 64];
    let mut len = buf.len();
    // SAFETY: the name is NUL-terminated; `buf` and `len` describe a writable buffer.
    let r = unsafe {
        libc::sysctlbyname(
            c"kern.bootsessionuuid".as_ptr(),
            buf.as_mut_ptr().cast(),
            &mut len,
            std::ptr::null_mut(),
            0,
        )
    };
    if r != 0 || len == 0 || len > buf.len() {
        return String::new();
    }
    String::from_utf8_lossy(&buf[..len])
        .trim_end_matches('\0')
        .to_owned()
}

#[cfg(not(any(
    target_os = "android",
    target_os = "linux",
    target_os = "ios",
    target_os = "macos"
)))]
fn boot_id() -> String {
    String::new()
}

#[cfg(test)]
mod tests {
    use super::*;

    const T: u64 = 1_795_132_800_000;
    const H: u64 = 3_600_000;

    fn boot(ms: u64) -> Boot {
        Boot {
            ms,
            id: "b1".into(),
        }
    }

    #[test]
    fn without_a_boot_id_a_time_from_an_earlier_process_is_stale() {
        // No boot id at all: nothing counts as the same boot, so nothing is carried.
        let none = |ms| Boot {
            ms,
            id: String::new(),
        };
        let c = RelayClock::learned(T, &none(H));
        let now = c.now(T + 30 * H, &none(H + 60_000));
        assert!(!now.fresh);
        assert_eq!(now.now, T + 30 * H);
        // The fallback id is this process's: learned and read in it, the clock is fresh.
        let here = boot_or_process_id(String::new());
        assert!(here.starts_with("process-"));
        assert_eq!(boot_or_process_id(String::new()), here);
        assert_eq!(boot_or_process_id("b1".into()), "b1");
        let mine = |ms| Boot {
            ms,
            id: here.clone(),
        };
        let c = RelayClock::learned(T, &mine(H));
        let now = c.now(T - 5 * H, &mine(H + 60_000));
        assert!(now.fresh);
        assert_eq!(now.now, T + 60_000);
        // Stored, then read by a later process after a reboot with a longer uptime: stale,
        // and the clock set back reads no earlier than the stored relay time.
        let stored: RelayClock = serde_json::from_str(&serde_json::to_string(&c).unwrap()).unwrap();
        let later = Boot {
            ms: 5 * H,
            id: "process-2-18000000".into(),
        };
        let now = stored.now(T - 5 * H, &later);
        assert!(!now.fresh);
        assert_eq!(now.now, T);
    }

    #[test]
    fn unknown_is_the_system_clock_and_not_fresh() {
        let c = RelayClock::default();
        assert_eq!(
            c.now(T, &boot(H)),
            ClockNow {
                now: T,
                fresh: false
            }
        );
    }

    #[test]
    fn fresh_follows_the_since_boot_clock_whatever_the_system_clock_says() {
        let c = RelayClock::learned(T, &boot(H));
        // The system clock set two hours forward, then a day back: ten minutes passed.
        for system in [T + 2 * H, T - 24 * H] {
            let n = c.now(system, &boot(H + 600_000));
            assert_eq!(
                n,
                ClockNow {
                    now: T + 600_000,
                    fresh: true
                }
            );
        }
    }

    #[test]
    fn stale_after_a_day_is_the_later_of_the_two() {
        let c = RelayClock::learned(T, &boot(H));
        let b = boot(H + 25 * H);
        assert_eq!(
            c.now(T, &b),
            ClockNow {
                now: T + 25 * H,
                fresh: false
            }
        );
        assert_eq!(
            c.now(T + 30 * H, &b),
            ClockNow {
                now: T + 30 * H,
                fresh: false
            }
        );
    }

    #[test]
    fn a_reboot_makes_it_stale_with_the_last_relay_time_as_a_floor() {
        let c = RelayClock::learned(T, &boot(5 * H));
        // The since-boot clock restarted.
        let n = c.now(T - H, &boot(H));
        assert_eq!(
            n,
            ClockNow {
                now: T,
                fresh: false
            }
        );
        // Another boot id, even with a longer uptime.
        let other = Boot {
            ms: 6 * H,
            id: "b2".into(),
        };
        assert_eq!(
            c.now(T + 3 * H, &other),
            ClockNow {
                now: T + 3 * H,
                fresh: false
            }
        );
        assert_eq!(
            c.now(T - 3 * H, &other),
            ClockNow {
                now: T,
                fresh: false
            }
        );
    }

    #[test]
    fn a_signed_call_far_from_it_makes_it_stale() {
        let mut c = RelayClock::learned(T, &boot(H));
        assert!(!c.signed_accepted(T + 4 * 60_000, T, &boot(H)));
        assert!(c.now(T, &boot(H)).fresh);
        assert!(c.signed_accepted(T + 10 * 60_000, T, &boot(H)));
        assert!(!c.now(T, &boot(H)).fresh);
        // Learning the relay's time again trusts it again.
        let c = RelayClock::learned(T + H, &boot(2 * H));
        assert!(c.now(T, &boot(2 * H)).fresh);
    }

    #[test]
    fn the_boot_clock_runs() {
        let a = boot_now();
        assert!(a.ms > 0);
        let b = boot_now();
        assert!(b.ms >= a.ms);
        assert_eq!(a.id, b.id);
    }
}
