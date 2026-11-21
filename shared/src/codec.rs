//! The plaintext inside the relay state blob: `{"v": 1, "state": {...}}` as UTF-8 JSON.

use serde::{Deserialize, Serialize};

use crate::error::{AppError, Result};
use crate::model::State;

/// The state plaintext format this app writes.
pub const STATE_FORMAT: u32 = 1;

#[derive(Serialize, Deserialize)]
struct Envelope {
    v: u32,
    #[serde(default)]
    state: State,
}

/// Encodes the state for `state_seal`.
#[uniffi::export]
pub fn encode_state(state: &State) -> Vec<u8> {
    serde_json::to_vec(&Envelope {
        v: STATE_FORMAT,
        state: state.clone(),
    })
    .expect("state serialises")
}

/// Decodes what `state_open` returned. An empty plaintext is the empty state.
#[uniffi::export]
pub fn decode_state(bytes: Vec<u8>) -> Result<State> {
    if bytes.is_empty() {
        return Ok(State::default());
    }
    #[derive(Deserialize)]
    struct V {
        v: u32,
    }
    let v: V = serde_json::from_slice(&bytes).map_err(|_| AppError::Decode)?;
    if v.v > STATE_FORMAT {
        return Err(AppError::NewerVersion);
    }
    let env: Envelope = serde_json::from_slice(&bytes).map_err(|_| AppError::Decode)?;
    Ok(env.state)
}

/// Shrinks a state whose encoding is over `limit` bytes: drops paths of stale inventory items,
/// then the oldest stale items (SPEC.md 6.5). Returns whether anything was shortened.
pub fn shrink_to_fit(state: &mut State, limit: usize) -> bool {
    let mut shortened = false;
    if encode_state(state).len() <= limit {
        return false;
    }
    for item in state
        .inventory
        .iter_mut()
        .filter(|i| i.stale && !i.path.is_empty())
    {
        item.path.clear();
        shortened = true;
    }
    while encode_state(state).len() > limit {
        let oldest = state
            .inventory
            .iter()
            .enumerate()
            .filter(|(_, i)| i.stale)
            .min_by_key(|(_, i)| i.last_use)
            .map(|(n, _)| n);
        match oldest {
            Some(n) => {
                state.inventory.remove(n);
                shortened = true;
            }
            None => break,
        }
    }
    shortened
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::{InventoryItem, Machine};

    #[test]
    fn round_trip_and_versions() {
        let mut s = State::default();
        s.machines.push(Machine {
            key: "k".into(),
            name: "dev@mbp.example.com".into(),
            ..Machine::default()
        });
        assert_eq!(decode_state(encode_state(&s)).unwrap(), s);
        assert_eq!(decode_state(Vec::new()).unwrap(), State::default());
        assert_eq!(
            decode_state(br#"{"v":2,"state":{}}"#.to_vec()),
            Err(AppError::NewerVersion)
        );
        assert_eq!(decode_state(b"nope".to_vec()), Err(AppError::Decode));
        // Unknown fields from a newer minor version are ignored.
        let s2 = decode_state(
            br#"{"v":1,"state":{"future":1,"machines":[{"key":"a","x":2}]}}"#.to_vec(),
        )
        .unwrap();
        assert_eq!(s2.machines[0].key, "a");
    }

    #[test]
    fn shrink_drops_stale_paths_then_items() {
        let mut s = State::default();
        for n in 0..50 {
            s.inventory.push(InventoryItem {
                id: format!("id{n}"),
                path: "x".repeat(200),
                stale: n < 40,
                last_use: n,
                ..InventoryItem::default()
            });
        }
        let full = encode_state(&s).len();
        assert!(!shrink_to_fit(&mut s.clone(), full));
        assert!(shrink_to_fit(&mut s, full - 100));
        assert!(s
            .inventory
            .iter()
            .filter(|i| i.stale)
            .all(|i| i.path.is_empty()));
        assert_eq!(s.inventory.len(), 50);
        let mut s3 = s.clone();
        let target = encode_state(&s3).len() - 500;
        assert!(shrink_to_fit(&mut s3, target));
        assert!(s3.inventory.len() < 50);
        assert!(s3.inventory.iter().filter(|i| !i.stale).count() == 10);
    }
}
