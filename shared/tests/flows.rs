//! Requests sealed by a machine through the core, decided and recorded by the app rules.

use std::sync::Arc;

use sealctl_app::decide::{decide, Asking, Biometrics, DecideContext, ReplyOption};
use sealctl_app::model::{Machine, WordsInfo};
use sealctl_app::store::{Event, Store};
use sealctl_core::machine::MachineKeys;
use sealctl_core::request::{new_request_id, open_request, seal_request};
use sealctl_core::wire::{
    AgentUse, Handback, HandbackItem, ObjectFacts, PlanBody, PlanItem, Repository, RequestBody,
    RequestContext, RequestItem, SessionState, Subject,
};
use sealctl_core::{PhoneKeys, PhonePublic, RequestKind, Root, Words};

fn phone() -> (Arc<Root>, PhoneKeys) {
    let words = Words::generate().unwrap();
    let root = Root::from_words(&words);
    let keys = PhoneKeys::from_root(&root);
    (Arc::new(root), keys)
}

fn now_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_millis() as u64
}

fn send(machine: &MachineKeys, keys: &PhoneKeys, body: RequestBody) -> Arc<sealctl_core::Request> {
    let phone = PhonePublic::from_b64u(&keys.public_id(), &keys.box_public_key()).unwrap();
    let id = new_request_id().unwrap();
    let sealed = seal_request(machine, &phone, &id, body).unwrap();
    open_request(keys, machine.id(), id, sealed.sealed).unwrap()
}

fn body(why: &str) -> RequestBody {
    RequestBody {
        v: 1,
        t: now_ms(),
        why: why.into(),
        ..RequestBody::default()
    }
}

fn ctx() -> DecideContext {
    DecideContext {
        now: now_ms(),
        utc_offset_secs: 0,
        phone_unlocked: true,
        near: false,
        on_wifi: false,
        location: sealctl_app::decide::LocationAccess::Off,
        current_place: None,
        current_place_settled: false,
        day: None,
        answers: Vec::new(),
        session_open: false,
        hold: None,
        biometrics: Biometrics::Available,
        plan: None,
    }
}

#[test]
fn open_from_agent_then_remembered() {
    let (_root, keys) = phone();
    let m = MachineKeys::generate().unwrap();
    let store = Store::open(":memory:".into()).unwrap();
    store
        .apply(Event::PairMachine {
            machine: Machine {
                key: m.id(),
                name: "dev@mbp.example.com".into(),
                ..Machine::default()
            },
            replaces: None,
        })
        .unwrap();
    store
        .apply(Event::SetWords {
            words: WordsInfo {
                fingerprint: "7Hq3".into(),
                ..WordsInfo::default()
            },
        })
        .unwrap();

    let mut b = body("open");
    b.ctx = Some(RequestContext {
        agent: Some("claude".into()),
        repo: Some(Repository {
            id: "github.com/acme/shop".into(),
            name: "shop".into(),
        }),
        command: "npm test".into(),
        cwd: "~/dev/shop".into(),
        user: "dev@mbp.example.com".into(),
        subject: Some(Subject {
            kind: "secret".into(),
            name: "OPENAI_API_KEY".into(),
        }),
        names: vec!["OPENAI_API_KEY".into()],
    });
    b.uses = vec![AgentUse {
        agent: "claude".into(),
        repository: "github.com/acme/shop".into(),
        names: vec!["OPENAI_API_KEY".into()],
    }];
    b.keys = vec![RequestItem {
        purpose: "secrets".into(),
        id: "store-1".into(),
        object: Some(ObjectFacts {
            kind: "store".into(),
            path: "~/.sealctl/store".into(),
            size: 14_000,
        }),
        ..RequestItem::default()
    }];
    let req = send(&m, &keys, b.clone());
    assert!(store
        .see_request(req.id(), req.machine(), now_ms() + 300_000)
        .unwrap());
    let v = decide(req.clone(), ctx());
    assert_eq!(v.asking, Asking::OneTap);
    assert!(v.agent_first_use);
    assert_eq!(v.options[0], ReplyOption::AllowSession);

    let r = store
        .answered(req.clone(), "one_tap".into(), true, true, None, false, 0)
        .unwrap();
    assert!(r.first_of_day);
    assert!(!store
        .see_request(req.id(), req.machine(), now_ms() + 300_000)
        .unwrap());
    let s = store.snapshot().unwrap();
    assert_eq!(s.live_answers().count(), 1);
    assert_eq!(s.inventory.len(), 1);
    assert_eq!(s.inventory[0].words, "7Hq3");
    assert_eq!(s.inventory[0].path, "~/.sealctl/store");
    let usage = store.usage(None, None, 10).unwrap();
    assert_eq!(usage[0].key, "OPENAI_API_KEY");
    assert_eq!(usage[0].agent.as_deref(), Some("claude"));

    // The same agent use now has an answer: an `agent` request answers by itself.
    let mut a = body("agent");
    a.uses = b.uses.clone();
    let req = send(&m, &keys, a);
    let mut c = ctx();
    c.answers = s.live_answers().cloned().collect();
    assert_eq!(decide(req.clone(), c).asking, Asking::Automatic);
    // A second open the same day is not the first of the day.
    let req = send(&m, &keys, b);
    assert!(
        !store
            .answered(req, "one_tap".into(), true, false, None, false, 0)
            .unwrap()
            .first_of_day
    );
    let month = sealctl_app::day::local_date(now_ms(), 0)[..7].to_owned();
    assert_eq!(store.summary(month).unwrap().keys_used, 2);
}

#[test]
fn report_with_status_and_handback() {
    let (_root, keys) = phone();
    let m = MachineKeys::generate().unwrap();
    let store = Store::open(":memory:".into()).unwrap();
    store
        .apply(Event::PairMachine {
            machine: Machine {
                key: m.id(),
                name: "dev@box".into(),
                ..Machine::default()
            },
            replaces: None,
        })
        .unwrap();
    let mut b = body("report");
    b.seq = Some(7);
    b.state = Some(SessionState {
        session: "open".into(),
        left: Some(3600),
        ..SessionState::default()
    });
    b.handback = Some(Handback {
        hash: "h".into(),
        items: vec![HandbackItem {
            kind: "volume".into(),
            name: "safe".into(),
            to: "macOS Keychain".into(),
            state: "done".into(),
        }],
        run: "~/.sealctl-unseal/x".into(),
    });
    let req = send(&m, &keys, b);
    assert_eq!(decide(req.clone(), ctx()).asking, Asking::Silent);
    let r = store.apply_report(req, 0).unwrap();
    assert_eq!(r.ack, Some(7));
    assert_eq!(r.handback.unwrap().items.len(), 1);
    let s = store.snapshot().unwrap();
    assert_eq!(
        s.machine(&m.id())
            .unwrap()
            .last_status
            .as_ref()
            .unwrap()
            .session,
        "open"
    );
    assert_eq!(s.reports.len(), 1);
}

#[test]
fn unseal_all_needs_number_and_delay() {
    let (_root, keys) = phone();
    let m = MachineKeys::generate().unwrap();
    let items = vec![
        PlanItem {
            kind: "volume".into(),
            name: "safe".into(),
            purpose: Some("volume".into()),
            id: Some("vol-1".into()),
        },
        PlanItem {
            kind: "pairing".into(),
            name: "dev@box".into(),
            ..PlanItem::default()
        },
    ];
    let h = sealctl_core::wire::PlanBody {
        all: true,
        h: base64url(&sealctl_core::plan::plan_hash(&m.id(), &items)),
        items,
        n: None,
        i: None,
    };
    let mut b = body("unseal");
    b.has_match = true;
    b.plan = Some(PlanBody { ..h });
    let req = send(&m, &keys, b);
    assert_eq!(req.kind(), RequestKind::Unseal);
    assert_eq!(req.level(), 3);
    let v = decide(req.clone(), ctx());
    assert_eq!(v.asking, Asking::InApp);
    assert!(v.needs_number && v.needs_biometrics && v.shows_plan);
    assert_eq!(v.delay_secs, 7200);
}

fn base64url(b: &[u8]) -> String {
    const A: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
    let mut out = String::new();
    for chunk in b.chunks(3) {
        let n = chunk
            .iter()
            .enumerate()
            .fold(0u32, |acc, (i, &x)| acc | (u32::from(x) << (16 - 8 * i)));
        let chars = chunk.len() + 1;
        for i in 0..chars {
            out.push(A[((n >> (18 - 6 * i)) & 63) as usize] as char);
        }
    }
    out
}
