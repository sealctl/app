//! Whole exchanges against the fake relay, with the core playing both the phone and a machine.

use std::sync::Arc;
use std::time::Duration;

use fake_machine::{b64u, next_json, random16, send_text, Relay, Signer, Socket};
use sealctl_core::channel::{open_message, seal_status};
use sealctl_core::pairing::{verify_pairing_proof, PairingLink};
use sealctl_core::request::{new_request_id, seal_request, SealedRequest};
use sealctl_core::wire::{
    MachineMessage, MachineStatus, MessageKind, ObjectFacts, RequestBody, RequestItem, SessionState,
};
use sealctl_core::{
    key_change_proof, licence_move_proof, open_machine_status, open_request, pairing_proof,
    seal_machine_message, seal_reply, Decision, MachineKeys, ObjectKey, PairingOffer, PhoneKeys,
    PhonePublic, Place, Purpose, Root, Words,
};
use serde_json::{json, Value};

const WORDS_B: &str =
    "bulk search gospel radio edit key flip afford jaguar rapid mechanic power family \
                       category snap boss iron web various grow smoke next example lounge";
const VOL: &str = "0f8e2c1a-7d3b-4e59-9a61-2b4c8d0e1f23";

struct Phone {
    root: Arc<Root>,
    keys: PhoneKeys,
}

impl Phone {
    fn b() -> Self {
        let words = Words::parse(WORDS_B.split_whitespace().map(str::to_owned).collect()).unwrap();
        let root = Root::from_words(&words);
        let keys = PhoneKeys::from_root(&root);
        Self {
            root: Arc::new(root),
            keys,
        }
    }
    fn id(&self) -> String {
        self.keys.public_id()
    }
    fn signer(&self) -> Signer<'_> {
        Signer::Phone(&self.keys)
    }
}

async fn relay() -> Relay {
    let addr = fake_relay::spawn("127.0.0.1:0").await.unwrap();
    Relay::new(&format!("http://{addr}"))
}

fn deadline(secs: u64) -> tokio::time::Instant {
    tokio::time::Instant::now() + Duration::from_secs(secs)
}

/// Pairs a new machine with the phone the way the app and `sealctl pair` do.
async fn pair(relay: &Relay, phone: &Phone) -> MachineKeys {
    let machine = MachineKeys::generate().unwrap();
    let code = random16().unwrap();
    let link = PairingLink {
        machine: machine.public(),
        machine_box: machine.box_public(),
        code: &code,
        name: "dev@mbp.example.com",
        os: "macOS 26",
        model: Some("MacBook Pro"),
        hint: None,
        expires: fake_machine::now_ms() / 1000 + 600,
        relay: Some(relay.base()),
    }
    .link();
    let offer = PairingOffer::parse(link).unwrap();
    let proof = pairing_proof(&phone.keys, &offer);
    let path = format!("/v1/phones/{}/machines", phone.id());
    let body = json!({"machine": offer.machine_key(), "name": offer.name(), "os": offer.os(), "proof": proof});
    let (status, res) = relay
        .call(&phone.signer(), "POST", &path, Some(&body))
        .await
        .unwrap();
    assert_eq!(status, 201, "{res}");
    assert_eq!(res["machines"], 1);

    let (status, res) = relay
        .call(
            &Signer::Machine(&machine),
            "GET",
            &format!("/v1/machines/{}", machine.id()),
            None,
        )
        .await
        .unwrap();
    assert_eq!(status, 200);
    let p: [u8; 32] = fake_machine::b64u_fixed(res["phone"].as_str().unwrap()).unwrap();
    let x =
        verify_pairing_proof(&code, machine.public(), &p, res["proof"].as_str().unwrap()).unwrap();
    assert_eq!(&x, phone.keys.box_public());
    machine
}

fn open_body(id: &str) -> RequestBody {
    RequestBody {
        v: 1,
        t: fake_machine::now_ms(),
        why: "open".into(),
        keys: vec![RequestItem {
            purpose: "volume".into(),
            id: id.into(),
            object: Some(ObjectFacts {
                kind: "volume".into(),
                path: "/Volumes/clients".into(),
                size: 1,
            }),
            ..RequestItem::default()
        }],
        ..RequestBody::default()
    }
}

/// The machine sends a request on a wait socket; returns the socket after `queued`.
async fn ask(
    relay: &Relay,
    machine: &MachineKeys,
    phone: &Phone,
    body: RequestBody,
) -> (SealedRequest, Socket) {
    let pub_ = PhonePublic::from_b64u(&phone.id(), &phone.keys.box_public_key()).unwrap();
    let sent = seal_request(machine, &pub_, &new_request_id().unwrap(), body).unwrap();
    let mut ws = relay
        .socket(
            &Signer::Machine(machine),
            &format!("/v1/phones/{}/wait", phone.id()),
        )
        .await
        .unwrap();
    send_text(
        &mut ws,
        &json!({"type": "request", "id": sent.id, "sealed": sent.sealed, "ttl": 60}).to_string(),
    )
    .await
    .unwrap();
    let queued = next_json(&mut ws, deadline(5)).await.unwrap().unwrap();
    assert_eq!(queued["type"], "queued");
    (sent, ws)
}

#[tokio::test(flavor = "multi_thread")]
async fn pair_request_reply_round_trip() {
    let relay = relay().await;
    let phone = Phone::b();
    let device = "AAAAAAAAAAAAAAAAAAAAAA";
    let (s, _) = relay
        .call(
            &phone.signer(),
            "PUT",
            &format!("/v1/phones/{}/push/{device}", phone.id()),
            Some(&json!({"platform": "fcm", "token": "tok:123"})),
        )
        .await
        .unwrap();
    assert_eq!(s, 200);
    let machine = pair(&relay, &phone).await;

    let mut phone_ws = relay
        .socket(
            &phone.signer(),
            &format!("/v1/phones/{}/socket", phone.id()),
        )
        .await
        .unwrap();
    let (sent, mut wait) = ask(&relay, &machine, &phone, open_body(VOL)).await;

    let note = next_json(&mut phone_ws, deadline(5))
        .await
        .unwrap()
        .unwrap();
    assert_eq!(note["type"], "request");
    assert_eq!(note["near"], true);
    assert_eq!(note["machine"], machine.id());

    let (s, list) = relay
        .call(
            &phone.signer(),
            "GET",
            &format!("/v1/phones/{}/requests", phone.id()),
            None,
        )
        .await
        .unwrap();
    assert_eq!(s, 200);
    let item = &list["requests"][0];
    assert_eq!(item["id"], sent.id.as_str());

    let req = open_request(
        &phone.keys,
        item["machine"].as_str().unwrap().into(),
        item["id"].as_str().unwrap().into(),
        item["sealed"].as_str().unwrap().into(),
    )
    .unwrap();
    let sealed = seal_reply(
        Some(phone.root.clone()),
        &phone.keys,
        &req,
        Decision::Session {
            place: Place::Trusted,
        },
    )
    .unwrap();
    let path = format!("/v1/phones/{}/requests/{}/reply", phone.id(), sent.id);
    let (s, res) = relay
        .call(
            &phone.signer(),
            "POST",
            &path,
            Some(&json!({ "sealed": sealed })),
        )
        .await
        .unwrap();
    assert_eq!((s, res["delivered"].clone()), (200, json!(true)));

    let msg = next_json(&mut wait, deadline(5)).await.unwrap().unwrap();
    assert_eq!(msg["type"], "reply");
    let reply = sent
        .open_reply(
            machine.public(),
            phone.keys.identity_public(),
            msg["sealed"].as_str().unwrap(),
        )
        .unwrap();
    assert!(reply.ok);
    assert_eq!(reply.grant.as_deref(), Some("session"));
    let want = ObjectKey::derive(&phone.root, Purpose::Volume, VOL)
        .unwrap()
        .b64u();
    assert_eq!(
        reply.keys[0].k.as_deref().map(String::as_str),
        Some(want.as_str())
    );

    // Answered once: the second reply finds nothing.
    let (s, res) = relay
        .call(
            &phone.signer(),
            "POST",
            &path,
            Some(&json!({ "sealed": sealed })),
        )
        .await
        .unwrap();
    assert_eq!((s, res["error"].clone()), (404, json!("gone")));

    let (_, replies) = relay.plain("GET", "/test/replies", None).await.unwrap();
    assert_eq!(replies["replies"].as_array().unwrap().len(), 1);
    let (_, pushes) = relay.plain("GET", "/test/pushes", None).await.unwrap();
    let pushes = pushes["pushes"].as_array().unwrap().clone();
    assert_eq!(pushes.len(), 1);
    assert_eq!(pushes[0]["type"], "request");
    assert_eq!(pushes[0]["id"], sent.id.as_str());

    let (s, machines) = relay
        .call(
            &phone.signer(),
            "GET",
            &format!("/v1/phones/{}/machines", phone.id()),
            None,
        )
        .await
        .unwrap();
    assert_eq!(s, 200);
    assert_eq!(machines["machines"][0]["name"], "dev@mbp.example.com");
    assert!(machines["machines"][0]["lastSeen"].is_u64());
}

#[tokio::test(flavor = "multi_thread")]
async fn signing_roles_and_forced_errors() {
    let relay = relay().await;
    let phone = Phone::b();
    let stranger = PhoneKeys::from_root(&Root::from_bytes(vec![7; 32]).unwrap());
    let path = format!("/v1/phones/{}/requests", phone.id());
    let (s, res) = relay
        .call(&Signer::Phone(&stranger), "GET", &path, None)
        .await
        .unwrap();
    assert_eq!((s, res["error"].clone()), (403, json!("forbidden")));
    let (s, res) = relay.plain("GET", &path, None).await.unwrap();
    assert_eq!((s, res["error"].clone()), (401, json!("unsigned")));

    let mut skewed = relay.clone();
    skewed.skew = 1000;
    let (s, res) = skewed
        .call(&phone.signer(), "GET", &path, None)
        .await
        .unwrap();
    assert_eq!((s, res["error"].clone()), (401, json!("clock_skew")));
    assert!(res["time"].is_u64());
    relay
        .plain("POST", "/test/clock", Some(&json!({"offset": 1000})))
        .await
        .unwrap();
    let (s, _) = skewed
        .call(&phone.signer(), "GET", &path, None)
        .await
        .unwrap();
    assert_eq!(s, 200);
    relay
        .plain("POST", "/test/clock", Some(&json!({"offset": 0})))
        .await
        .unwrap();

    relay
        .plain(
            "POST",
            "/test/fail",
            Some(&json!({"status": 429, "error": "rate_limited", "path": "/requests", "retryAfter": 60, "scope": "phone"})),
        )
        .await
        .unwrap();
    let (s, res) = relay
        .call(&phone.signer(), "GET", &path, None)
        .await
        .unwrap();
    assert_eq!(
        (s, res["retryAfter"].clone(), res["scope"].clone()),
        (429, json!(60), json!("phone"))
    );
    let (s, _) = relay
        .call(&phone.signer(), "GET", &path, None)
        .await
        .unwrap();
    assert_eq!(s, 200);
}

#[tokio::test(flavor = "multi_thread")]
async fn state_compare_and_swap() {
    let relay = relay().await;
    let phone = Phone::b();
    let path = format!("/v1/phones/{}/state", phone.id());
    let (_, res) = relay
        .call(&phone.signer(), "GET", &path, None)
        .await
        .unwrap();
    assert_eq!(res, json!({"rev": 0, "blob": null}));
    let blob = sealctl_core::state_seal(&phone.root, b"{}".to_vec()).unwrap();
    let (s, res) = relay
        .call(
            &phone.signer(),
            "PUT",
            &path,
            Some(&json!({"rev": 0, "blob": blob})),
        )
        .await
        .unwrap();
    assert_eq!((s, res), (200, json!({"rev": 1})));
    let (s, res) = relay
        .call(
            &phone.signer(),
            "PUT",
            &path,
            Some(&json!({"rev": 0, "blob": blob})),
        )
        .await
        .unwrap();
    assert_eq!((s, res), (409, json!({"error": "conflict", "rev": 1})));
    let (_, res) = relay
        .call(&phone.signer(), "GET", &path, None)
        .await
        .unwrap();
    let opened =
        sealctl_core::state_open(&phone.root, res["blob"].as_str().unwrap().into()).unwrap();
    assert_eq!(opened, b"{}");
}

#[tokio::test(flavor = "multi_thread")]
async fn delayed_reply_and_phone_action() {
    let relay = relay().await;
    let phone = Phone::b();
    let machine = pair(&relay, &phone).await;
    let (sent, mut wait) = ask(&relay, &machine, &phone, open_body(VOL)).await;
    let req = open_request(
        &phone.keys,
        machine.id(),
        sent.id.clone(),
        sent.sealed.clone(),
    )
    .unwrap();
    let sealed = seal_reply(
        Some(phone.root.clone()),
        &phone.keys,
        &req,
        Decision::Once {
            place: Place::Other,
        },
    )
    .unwrap();
    let p = phone.id();
    let (s, res) = relay
        .call(
            &phone.signer(),
            "POST",
            &format!("/v1/phones/{p}/requests/{}/reply", sent.id),
            Some(&json!({"sealed": sealed, "delay": 1})),
        )
        .await
        .unwrap();
    assert_eq!(s, 200, "{res}");
    let msg = next_json(&mut wait, deadline(5)).await.unwrap().unwrap();
    assert_eq!(msg["type"], "delayed");

    let one = format!("/v1/phones/{p}/delayed/{}", sent.id);
    let m = Signer::Machine(&machine);
    let (_, early) = relay.call(&m, "GET", &one, None).await.unwrap();
    assert_eq!(early["state"], "waiting");
    assert!(early.get("sealed").is_none());
    tokio::time::sleep(Duration::from_millis(1100)).await;
    let (_, late) = relay.call(&m, "GET", &one, None).await.unwrap();
    let reply = sent
        .open_reply(
            machine.public(),
            phone.keys.identity_public(),
            late["sealed"].as_str().unwrap(),
        )
        .unwrap();
    assert!(reply.ok);
    let (s, _) = relay.call(&m, "GET", &one, None).await.unwrap();
    assert_eq!(s, 404, "fetched once, then gone");

    // An action on the phone: too early, cancelled by the machine, then refused.
    let id = new_request_id().unwrap();
    let (s, res) = relay
        .call(
            &phone.signer(),
            "POST",
            &format!("/v1/phones/{p}/delayed"),
            Some(&json!({"id": id, "delay": 3600})),
        )
        .await
        .unwrap();
    assert_eq!(s, 201, "{res}");
    // kept an hour after `releaseAt` for the person to come back and finish it
    assert_eq!(
        res["expires"].as_u64(),
        res["releaseAt"].as_u64().map(|r| r + 3_600_000),
        "{res}"
    );
    let finish = format!("/v1/phones/{p}/delayed/{id}/finish");
    let (s, res) = relay
        .call(&phone.signer(), "POST", &finish, None)
        .await
        .unwrap();
    assert_eq!((s, res["error"].clone()), (425, json!("too_early")));
    let (s, _) = relay
        .call(
            &m,
            "POST",
            &format!("/v1/phones/{p}/delayed/{id}/cancel"),
            None,
        )
        .await
        .unwrap();
    assert_eq!(s, 200);
    let (s, res) = relay
        .call(&phone.signer(), "POST", &finish, None)
        .await
        .unwrap();
    assert_eq!((s, res["by"].clone()), (409, json!(machine.id())));
    let (_, pushes) = relay.plain("GET", "/test/pushes", None).await.unwrap();
    assert_eq!(pushes["pushes"], json!([]), "no device registered");
}

#[tokio::test(flavor = "multi_thread")]
async fn machine_channel_status_and_messages() {
    let relay = relay().await;
    let phone = Phone::b();
    let machine = pair(&relay, &phone).await;
    let p = phone.id();
    let mut phone_ws = relay
        .socket(&phone.signer(), &format!("/v1/phones/{p}/socket"))
        .await
        .unwrap();

    let pub_ = PhonePublic::from_b64u(&p, &phone.keys.box_public_key()).unwrap();
    let status = MachineStatus {
        version: 1,
        time: fake_machine::now_ms(),
        seq: 1,
        state: Some(SessionState {
            session: "open".into(),
            left: Some(3600),
            ..SessionState::default()
        }),
        ..MachineStatus::default()
    };
    let sealed = seal_status(&machine, &pub_, &status).unwrap();
    let m = Signer::Machine(&machine);
    let (s, _) = relay
        .call(
            &m,
            "PUT",
            &format!("/v1/phones/{p}/machines/{}/status", machine.id()),
            Some(&json!({"sealed": sealed})),
        )
        .await
        .unwrap();
    assert_eq!(s, 200);
    let note = next_json(&mut phone_ws, deadline(5))
        .await
        .unwrap()
        .unwrap();
    assert_eq!(note, json!({"type": "status", "machine": machine.id()}));
    let (_, list) = relay
        .call(
            &phone.signer(),
            "GET",
            &format!("/v1/phones/{p}/status"),
            None,
        )
        .await
        .unwrap();
    let got = open_machine_status(
        &phone.keys,
        machine.id(),
        list["status"][0]["sealed"].as_str().unwrap().into(),
    )
    .unwrap();
    assert_eq!(got.state.unwrap().left, Some(3600));

    let lock = |seq| MachineMessage {
        version: 1,
        time: fake_machine::now_ms(),
        seq,
        kind: MessageKind::Lock {
            reason: "phone".into(),
        },
    };
    let msgs = format!("/v1/phones/{p}/machines/{}/messages", machine.id());
    let sealed = seal_machine_message(
        &phone.keys,
        machine.id(),
        b64u(machine.box_public()),
        lock(1),
    )
    .unwrap();
    let (_, res) = relay
        .call(
            &phone.signer(),
            "POST",
            &msgs,
            Some(&json!({"sealed": sealed})),
        )
        .await
        .unwrap();
    assert_eq!(res["delivered"], false);

    let mut sock = relay
        .socket(
            &m,
            &format!("/v1/phones/{p}/machines/{}/socket", machine.id()),
        )
        .await
        .unwrap();
    let held = next_json(&mut sock, deadline(5)).await.unwrap().unwrap();
    let opened = open_message(
        &machine,
        phone.keys.identity_public(),
        held["sealed"].as_str().unwrap(),
    )
    .unwrap();
    assert_eq!(opened.seq, 1);
    let sealed = seal_machine_message(
        &phone.keys,
        machine.id(),
        b64u(machine.box_public()),
        lock(2),
    )
    .unwrap();
    let (_, res) = relay
        .call(
            &phone.signer(),
            "POST",
            &msgs,
            Some(&json!({"sealed": sealed})),
        )
        .await
        .unwrap();
    assert_eq!(res["delivered"], true);
    let live: Value = next_json(&mut sock, deadline(5)).await.unwrap().unwrap();
    assert_eq!(
        open_message(
            &machine,
            phone.keys.identity_public(),
            live["sealed"].as_str().unwrap()
        )
        .unwrap()
        .seq,
        2
    );
}

#[tokio::test(flavor = "multi_thread")]
async fn unpair_and_delete_phone_close_waits() {
    let relay = relay().await;
    let phone = Phone::b();
    let machine = pair(&relay, &phone).await;
    let (_, mut wait) = ask(&relay, &machine, &phone, open_body(VOL)).await;
    let p = phone.id();
    let (s, res) = relay
        .call(&phone.signer(), "DELETE", &format!("/v1/phones/{p}"), None)
        .await
        .unwrap();
    assert_eq!((s, res), (200, json!({"deleted": true, "machines": 1})));
    let msg = next_json(&mut wait, deadline(5)).await.unwrap().unwrap();
    assert_eq!(msg, json!({"type": "error", "error": "unpaired"}));
    let (s, _) = relay
        .call(
            &Signer::Machine(&machine),
            "GET",
            &format!("/v1/machines/{}", machine.id()),
            None,
        )
        .await
        .unwrap();
    assert_eq!(s, 404);
}

async fn listed(relay: &Relay, keys: &PhoneKeys) -> usize {
    let path = format!("/v1/phones/{}/machines", keys.public_id());
    let (_, res) = relay
        .call(&Signer::Phone(keys), "GET", &path, None)
        .await
        .unwrap();
    res["machines"].as_array().unwrap().len()
}

#[tokio::test(flavor = "multi_thread")]
async fn moves_need_a_proof_from_the_current_phone() {
    let relay = relay().await;
    let phone = Phone::b();
    let machine = pair(&relay, &phone).await;
    let other = PhoneKeys::from_root(&Root::from_bytes(vec![7; 32]).unwrap());
    let path = format!("/v1/phones/{}/machines", other.public_id());

    // Without a proof, with a proof signed by the wrong phone: refused, nothing changes.
    let forged = key_change_proof(&other, &other, machine.id()).unwrap();
    for proof in [None, Some("A".repeat(128)), Some(forged)] {
        let mut body = json!({"machine": machine.id(), "name": "x"});
        if let Some(p) = proof {
            body["proof"] = json!(p);
        }
        let (s, res) = relay
            .call(&Signer::Phone(&other), "POST", &path, Some(&body))
            .await
            .unwrap();
        assert_eq!(
            (s, res["error"].clone()),
            (400, json!("bad_proof")),
            "{body}"
        );
    }
    assert_eq!(listed(&relay, &phone.keys).await, 1);
    assert_eq!(listed(&relay, &other).await, 0);

    // With the current phone's move proof the machine moves.
    let proof = key_change_proof(&phone.keys, &other, machine.id()).unwrap();
    let body = json!({"machine": machine.id(), "name": "x", "proof": proof});
    let (s, res) = relay
        .call(&Signer::Phone(&other), "POST", &path, Some(&body))
        .await
        .unwrap();
    assert_eq!(s, 201, "{res}");
    assert_eq!(listed(&relay, &phone.keys).await, 0);
    assert_eq!(listed(&relay, &other).await, 1);

    // The licence move proof is the new key's signature.
    let path = format!("/v1/phones/{}/licence/move", phone.id());
    let wrong = licence_move_proof(&phone.keys, phone.id()).unwrap();
    let right = licence_move_proof(&other, phone.id()).unwrap();
    for (proof, want) in [(wrong, 400), (right, 200)] {
        let body = json!({"to": other.public_id(), "proof": proof});
        let (s, res) = relay
            .call(&phone.signer(), "POST", &path, Some(&body))
            .await
            .unwrap();
        assert_eq!(s, want, "{res}");
    }
}
