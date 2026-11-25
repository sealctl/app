//! `sealctl-app`: what both phone apps must do the same way (SPEC.md 5.1): the state model and
//! its encoding, the merge of state versions, the levels of asking, the day record, place
//! clustering, lifetimes, the monthly summary and the card checks. Built into one library with
//! `sealctl-core` (`libsealctl_app`), exported through UniFFI.

uniffi::setup_scaffolding!();

pub mod activity;
pub mod cards;
pub mod clock;
pub mod codec;
pub mod day;
pub mod decide;
pub mod error;
pub mod machine_model;
pub mod merge;
pub mod model;
pub mod places;
pub mod prune;
pub mod store;

pub use sealctl_core;

/// This crate's version.
#[uniffi::export]
pub fn app_rules_version() -> String {
    env!("CARGO_PKG_VERSION").to_owned()
}
