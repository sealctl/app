//! The model a machine reported, as the Machines list shows it (SPEC.md 11.17): a Mac's model
//! identifier (`Mac16,10`) becomes its family name (`Mac mini`); anything else (a Linux
//! machine's product name, a Mac this table does not know) is shown as it was reported.

use crate::cards::display_text;

/// Longest model shown.
const MAX_MODEL: u32 = 60;

/// Model identifiers of the `MacN,M` kind, which do not say what they are. The older kind
/// (`MacBookPro18,3`, `Macmini9,1`, `iMac21,1`) is read from its prefix in [`family`].
const MAC_MODELS: &[(&str, &str)] = &[
    // Mac mini: M2, M2 Pro (2023); M4, M4 Pro (2024)
    ("Mac14,3", "Mac mini"),
    ("Mac14,12", "Mac mini"),
    ("Mac16,10", "Mac mini"),
    ("Mac16,11", "Mac mini"),
    // MacBook Air: M2 13 and 15 inch; M3 13 and 15 inch; M4 13 and 15 inch
    ("Mac14,2", "MacBook Air"),
    ("Mac14,15", "MacBook Air"),
    ("Mac15,12", "MacBook Air"),
    ("Mac15,13", "MacBook Air"),
    ("Mac16,12", "MacBook Air"),
    ("Mac16,13", "MacBook Air"),
    // MacBook Pro: M2 (13, 14, 16 inch); M3, M3 Pro, M3 Max (14, 16 inch); M4, M4 Pro, M4 Max
    ("Mac14,5", "MacBook Pro"),
    ("Mac14,6", "MacBook Pro"),
    ("Mac14,7", "MacBook Pro"),
    ("Mac14,9", "MacBook Pro"),
    ("Mac14,10", "MacBook Pro"),
    ("Mac15,3", "MacBook Pro"),
    ("Mac15,6", "MacBook Pro"),
    ("Mac15,7", "MacBook Pro"),
    ("Mac15,8", "MacBook Pro"),
    ("Mac15,9", "MacBook Pro"),
    ("Mac15,10", "MacBook Pro"),
    ("Mac15,11", "MacBook Pro"),
    ("Mac16,1", "MacBook Pro"),
    ("Mac16,5", "MacBook Pro"),
    ("Mac16,6", "MacBook Pro"),
    ("Mac16,7", "MacBook Pro"),
    ("Mac16,8", "MacBook Pro"),
    // iMac 24 inch: M3; M4
    ("Mac15,4", "iMac"),
    ("Mac15,5", "iMac"),
    ("Mac16,2", "iMac"),
    ("Mac16,3", "iMac"),
    // Mac Studio: M1 Max, M1 Ultra; M2 Max, M2 Ultra; M3 Ultra; M4 Max
    ("Mac13,1", "Mac Studio"),
    ("Mac13,2", "Mac Studio"),
    ("Mac14,13", "Mac Studio"),
    ("Mac14,14", "Mac Studio"),
    ("Mac15,14", "Mac Studio"),
    ("Mac16,9", "Mac Studio"),
    // Mac Pro: M2 Ultra
    ("Mac14,8", "Mac Pro"),
];

/// Older identifiers name their family before the numbers; longer prefixes first.
const MAC_PREFIXES: &[(&str, &str)] = &[
    ("MacBookAir", "MacBook Air"),
    ("MacBookPro", "MacBook Pro"),
    ("MacBook", "MacBook"),
    ("Macmini", "Mac mini"),
    ("iMacPro", "iMac Pro"),
    ("iMac", "iMac"),
    ("MacPro", "Mac Pro"),
];

/// The model as the Machines list shows it: `Mac16,10` → `Mac mini`, `MacBookPro18,3` →
/// `MacBook Pro`; any other value as reported, made safe to show (SPEC.md 11.7) and at most
/// 60 characters. Empty when the machine reported nothing.
#[uniffi::export]
pub fn machine_model_name(model: String) -> String {
    let model = model.trim();
    match family(model) {
        Some(name) => name.to_owned(),
        None => display_text(model.to_owned(), MAX_MODEL),
    }
}

fn family(model: &str) -> Option<&'static str> {
    if let Some((_, name)) = MAC_MODELS.iter().find(|(id, _)| *id == model) {
        return Some(name);
    }
    MAC_PREFIXES.iter().find_map(|(prefix, name)| {
        model
            .strip_prefix(prefix)
            .filter(|rest| is_version(rest))
            .map(|_| *name)
    })
}

/// `18,3`: digits, a comma, digits.
fn is_version(s: &str) -> bool {
    let digits = |p: &str| !p.is_empty() && p.bytes().all(|b| b.is_ascii_digit());
    s.split_once(',')
        .is_some_and(|(major, minor)| digits(major) && digits(minor))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn name(model: &str) -> String {
        machine_model_name(model.into())
    }

    #[test]
    fn mac_identifiers_become_their_family() {
        assert_eq!(name("Mac16,10"), "Mac mini");
        assert_eq!(name("Mac16,11"), "Mac mini");
        assert_eq!(name("Mac15,12"), "MacBook Air");
        assert_eq!(name("Mac16,1"), "MacBook Pro");
        assert_eq!(name("Mac16,3"), "iMac");
        assert_eq!(name("Mac16,9"), "Mac Studio");
        assert_eq!(name("Mac14,8"), "Mac Pro");
        assert_eq!(name(" Mac14,2\n"), "MacBook Air");
    }

    #[test]
    fn older_identifiers_are_read_from_their_prefix() {
        assert_eq!(name("Macmini9,1"), "Mac mini");
        assert_eq!(name("MacBookAir10,1"), "MacBook Air");
        assert_eq!(name("MacBookPro18,3"), "MacBook Pro");
        assert_eq!(name("MacBook10,1"), "MacBook");
        assert_eq!(name("iMac21,1"), "iMac");
        assert_eq!(name("iMacPro1,1"), "iMac Pro");
        assert_eq!(name("MacPro7,1"), "Mac Pro");
    }

    #[test]
    fn anything_else_is_shown_as_reported() {
        // a Mac this table does not know yet
        assert_eq!(name("Mac99,1"), "Mac99,1");
        assert_eq!(name("MacBookPro"), "MacBookPro");
        assert_eq!(name("MacBookPro18"), "MacBookPro18");
        assert_eq!(name("MacBookProX1,1"), "MacBookProX1,1");
        // Linux machines report their product name
        assert_eq!(
            name("ThinkPad X1 Carbon Gen 11"),
            "ThinkPad X1 Carbon Gen 11"
        );
        assert_eq!(name("MacBook Pro"), "MacBook Pro");
        assert_eq!(name(""), "");
    }

    #[test]
    fn a_reported_model_is_made_safe() {
        assert_eq!(name("Think\u{202E}Pad"), "Think\u{FFFD}Pad");
        assert_eq!(name(&"x".repeat(100)).chars().count(), 60);
    }

    #[test]
    fn every_identifier_is_listed_once() {
        let mut ids: Vec<_> = MAC_MODELS.iter().map(|(id, _)| *id).collect();
        ids.sort_unstable();
        let n = ids.len();
        ids.dedup();
        assert_eq!(ids.len(), n);
        assert!(MAC_MODELS
            .iter()
            .all(|(id, _)| id.strip_prefix("Mac").is_some_and(is_version)));
    }
}
