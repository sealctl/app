//! The card checks (SPEC.md 11.3 step 6, 11.16, 11.23): positions, choices and typed words.
//! The words stay inside the core's `Words` object; only the four choices and a yes or no
//! cross to the app.

use std::collections::hash_map::RandomState;
use std::hash::{BuildHasher, Hasher};
use std::sync::Arc;

use sealctl_core::{complete_word, Words};

/// A small random source for choosing positions and shuffling choices (not for keys).
pub(crate) fn random_u64() -> u64 {
    let mut h = RandomState::new().build_hasher();
    h.write_u128(
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_nanos())
            .unwrap_or(0),
    );
    h.finish()
}

fn below(n: u64) -> u64 {
    random_u64() % n.max(1)
}

/// Random 22-character id (16 bytes of base64url-ish text from the alphabet below).
#[uniffi::export]
pub fn random_id() -> String {
    const A: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
    (0..22).map(|_| A[below(64) as usize] as char).collect()
}

/// Card positions from 1 to 24 for a check: `count` positions spread over `groups` equal
/// parts (onboarding 3 over 2 halves; yearly 2 over 2; leaving 3 over 3), in order.
#[uniffi::export]
pub fn card_positions(count: u32, groups: u32) -> Vec<u32> {
    let groups = groups.clamp(1, 24);
    let size = 24 / groups;
    let mut out: Vec<u32> = Vec::new();
    for g in 0..groups.min(count) {
        out.push(g * size + 1 + below(u64::from(size)) as u32);
    }
    while (out.len() as u32) < count {
        let p = 1 + below(24) as u32;
        if !out.contains(&p) {
            out.push(p);
        }
    }
    out.sort_unstable();
    out
}

/// Four choices for word `position` (1 to 24): the right word and three BIP39 words with the
/// same first letter, shuffled.
#[uniffi::export]
pub fn card_choices(words: Arc<Words>, position: u32) -> Vec<String> {
    let list = words.list();
    let Some(right) = list.get(position.saturating_sub(1) as usize).cloned() else {
        return Vec::new();
    };
    let first: String = right.chars().take(1).collect();
    let mut pool: Vec<String> = complete_word(first)
        .into_iter()
        .filter(|w| *w != right)
        .collect();
    let mut out = vec![right];
    while out.len() < 4 && !pool.is_empty() {
        let n = below(pool.len() as u64) as usize;
        out.push(pool.swap_remove(n));
    }
    for i in (1..out.len()).rev() {
        out.swap(i, below(i as u64 + 1) as usize);
    }
    out
}

/// Whether `typed` (a full word, or four or more letters that name one word) is word
/// `position` (1 to 24).
#[uniffi::export]
pub fn card_word_matches(words: Arc<Words>, position: u32, typed: String) -> bool {
    let list = words.list();
    let Some(right) = list.get(position.saturating_sub(1) as usize) else {
        return false;
    };
    let typed = typed.trim().to_lowercase();
    if &typed == right {
        return true;
    }
    if typed.chars().count() < 4 {
        return false;
    }
    let found = complete_word(typed);
    found.len() == 1 && &found[0] == right
}

/// Keypad state for a typed word: the letters that can come next, and the completed word
/// once the prefix names exactly one word.
#[derive(uniffi::Record, Debug, Clone, PartialEq, Eq)]
pub struct WordEntry {
    /// Letters `a` to `z` that keep the prefix valid.
    pub next_letters: Vec<String>,
    /// The only word starting with the prefix, when there is one.
    pub completed: Option<String>,
    /// The prefix is itself a whole word (for example `act`, which also starts `action`).
    pub exact: bool,
    /// No BIP39 word starts with the prefix.
    pub invalid: bool,
}

/// Drives the word keypad (SPEC.md 11.4).
#[uniffi::export]
pub fn word_entry(prefix: String) -> WordEntry {
    let prefix = prefix.trim().to_lowercase();
    let matches = if prefix.is_empty() {
        Vec::new()
    } else {
        complete_word(prefix.clone())
    };
    let next: Vec<String> = ('a'..='z')
        .filter(|c| !complete_word(format!("{prefix}{c}")).is_empty())
        .map(|c| c.to_string())
        .collect();
    WordEntry {
        next_letters: next,
        completed: (matches.len() == 1).then(|| matches[0].clone()),
        exact: matches.contains(&prefix),
        invalid: !prefix.is_empty() && matches.is_empty(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn words_b() -> Arc<Words> {
        let list = "bulk search gospel radio edit key flip afford jaguar rapid mechanic power family category snap boss iron web various grow smoke next example lounge";
        Arc::new(Words::parse(list.split(' ').map(String::from).collect()).unwrap())
    }

    #[test]
    fn positions_spread_over_groups() {
        for _ in 0..50 {
            let p = card_positions(3, 2);
            assert_eq!(p.len(), 3);
            assert!(p.iter().any(|&x| x <= 12) && p.iter().any(|&x| x > 12));
            let mut d = p.clone();
            d.dedup();
            assert_eq!(d.len(), 3);
            let p = card_positions(3, 3);
            assert!(p[0] <= 8 && (9..=16).contains(&p[1]) && p[2] > 16);
            let p = card_positions(2, 2);
            assert!(p[0] <= 12 && p[1] > 12);
        }
    }

    #[test]
    fn choices_share_the_first_letter() {
        let w = words_b();
        let c = card_choices(w.clone(), 7);
        assert_eq!(c.len(), 4);
        assert!(c.contains(&"flip".to_string()));
        assert!(c.iter().all(|x| x.starts_with('f')));
        let mut d = c.clone();
        d.sort();
        d.dedup();
        assert_eq!(d.len(), 4);
        assert!(card_choices(w, 25).is_empty());
    }

    #[test]
    fn typed_words() {
        let w = words_b();
        assert!(card_word_matches(w.clone(), 1, "bulk".into()));
        assert!(card_word_matches(w.clone(), 2, "sear".into()));
        assert!(card_word_matches(w.clone(), 2, " SEARCH ".into()));
        assert!(!card_word_matches(w.clone(), 2, "sea".into()));
        assert!(!card_word_matches(w, 3, "bulk".into()));
    }

    #[test]
    fn keypad() {
        let e = word_entry("".into());
        assert_eq!(e.next_letters.len(), 26 - 1); // no BIP39 word starts with x
        let e = word_entry("ab".into());
        assert_eq!(e.completed, None);
        let e = word_entry("ocea".into());
        assert_eq!(e.completed.as_deref(), Some("ocean"));
        let e = word_entry("qz".into());
        assert!(e.invalid);
        let e = word_entry("act".into());
        assert!(e.exact && e.completed.is_none());
        assert_eq!(
            word_entry("acti".into()).completed.as_deref(),
            Some("action")
        );
    }
}
