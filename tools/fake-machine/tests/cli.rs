//! The `fake-machine` binary against the fake relay, with the core playing the phone.

use std::path::PathBuf;
use std::process::Stdio;
use std::sync::Arc;
use std::time::Duration;

use fake_machine::{Relay, Signer};
use sealctl_core::{
    open_request, pairing_proof, seal_plan_part_reply, seal_reply, Decision, PairingOffer,
    PhoneKeys, Place, PlanAssembler, Request, Root, Words,
};
use serde_json::json;
use tokio::io::{AsyncBufReadExt, BufReader};
use tokio::process::Command;
use tokio::sync::mpsc;

const WORDS_B: &str =
    "bulk search gospel radio edit key flip afford jaguar rapid mechanic power family \
                       category snap boss iron web various grow smoke next example lounge";
const VOL: &str = "0f8e2c1a-7d3b-4e59-9a61-2b4c8d0e1f23";

struct Ctx {
    relay: Relay,
    home: PathBuf,
    root: Arc<Root>,
    keys: PhoneKeys,
}

impl Ctx {
    async fn new() -> Self {
        let addr = fake_relay::spawn("127.0.0.1:0").await.unwrap();
        let words = Words::parse(WORDS_B.split_whitespace().map(str::to_owned).collect()).unwrap();
        let root = Root::from_words(&words);
        let keys = PhoneKeys::from_root(&root);
        let home = std::env::temp_dir().join(format!(
            "fake-machine-test-{}",
            fake_machine::b64u(&fake_machine::random16().unwrap())
        ));
        Self {
            relay: Relay::new(&format!("http://{addr}")),
            home,
            root: Arc::new(root),
            keys,
        }
    }

    fn cmd(&self, args: &[&str]) -> Command {
        let mut c = Command::new(env!("CARGO_BIN_EXE_fake-machine"));
        c.arg("--home")
            .arg(&self.home)
            .arg("--relay")
            .arg(self.relay.base())
            .args(args);
        c.stdout(Stdio::piped())
            .stderr(Stdio::null())
            .kill_on_drop(true);
        c
    }

    async fn run(&self, args: &[&str]) -> (i32, String) {
        let out = self.cmd(args).output().await.unwrap();
        (
            out.status.code().unwrap_or(-1),
            String::from_utf8_lossy(&out.stdout).into_owned(),
        )
    }

    /// Starts a request in the background; its stdout lines arrive on the channel.
    fn start(&self, args: &[&str]) -> (tokio::process::Child, mpsc::UnboundedReceiver<String>) {
        let mut child = self.cmd(args).spawn().unwrap();
        let stdout = child.stdout.take().unwrap();
        let (tx, rx) = mpsc::unbounded_channel();
        tokio::spawn(async move {
            let mut lines = BufReader::new(stdout).lines();
            while let Ok(Some(l)) = lines.next_line().await {
                let _ = tx.send(l);
            }
        });
        (child, rx)
    }

    /// Waits for the next pending request and opens it as the phone.
    async fn next_request(&self, skip: &[String]) -> Arc<Request> {
        let path = format!("/v1/phones/{}/requests", self.keys.public_id());
        for _ in 0..100 {
            let (_, list) = self
                .relay
                .call(&Signer::Phone(&self.keys), "GET", &path, None)
                .await
                .unwrap();
            if let Some(r) = list["requests"]
                .as_array()
                .unwrap()
                .iter()
                .find(|r| !skip.contains(&r["id"].as_str().unwrap().to_owned()))
            {
                return open_request(
                    &self.keys,
                    r["machine"].as_str().unwrap().into(),
                    r["id"].as_str().unwrap().into(),
                    r["sealed"].as_str().unwrap().into(),
                )
                .unwrap();
            }
            tokio::time::sleep(Duration::from_millis(100)).await;
        }
        panic!("no request arrived");
    }

    async fn answer(&self, req: &Request, sealed: String) {
        let path = format!(
            "/v1/phones/{}/requests/{}/reply",
            self.keys.public_id(),
            req.id()
        );
        let (s, res) = self
            .relay
            .call(
                &Signer::Phone(&self.keys),
                "POST",
                &path,
                Some(&json!({ "sealed": sealed })),
            )
            .await
            .unwrap();
        assert_eq!(s, 200, "{res}");
    }
}

async fn finish(
    mut child: tokio::process::Child,
    mut rx: mpsc::UnboundedReceiver<String>,
) -> (i32, Vec<String>) {
    let status = tokio::time::timeout(Duration::from_secs(20), child.wait())
        .await
        .unwrap()
        .unwrap();
    let mut lines = Vec::new();
    while let Ok(Some(l)) = tokio::time::timeout(Duration::from_millis(500), rx.recv()).await {
        lines.push(l);
    }
    (status.code().unwrap_or(-1), lines)
}

fn has(lines: &[String], text: &str) -> bool {
    lines.iter().any(|l| l.contains(text))
}

#[tokio::test(flavor = "multi_thread")]
async fn pair_open_unseal_and_deny() {
    let ctx = Ctx::new().await;

    let (code, out) = ctx
        .run(&[
            "pair",
            "--no-wait",
            "--name",
            "dev@mbp.example.com",
            "--model",
            "MacBook Pro",
            "--hint-raw",
            "serial-1",
        ])
        .await;
    assert_eq!(code, 0, "{out}");
    let link = out
        .lines()
        .find_map(|l| l.strip_prefix("LINK "))
        .unwrap()
        .to_owned();
    let offer = PairingOffer::parse(link).unwrap();
    assert_eq!(offer.model().as_deref(), Some("MacBook Pro"));
    assert!(offer.hint().is_some());
    assert_eq!(offer.relay_origin(), ctx.relay.base());
    let body = json!({"machine": offer.machine_key(), "name": offer.name(), "os": offer.os(),
                      "proof": pairing_proof(&ctx.keys, &offer)});
    let (s, _) = ctx
        .relay
        .call(
            &Signer::Phone(&ctx.keys),
            "POST",
            &format!("/v1/phones/{}/machines", ctx.keys.public_id()),
            Some(&body),
        )
        .await
        .unwrap();
    assert_eq!(s, 201);
    let (code, out) = ctx.run(&["pair-wait", "--wait-secs", "10"]).await;
    assert_eq!(code, 0);
    assert!(out.contains(&format!("PAIRED phone={}", ctx.keys.public_id())));

    // A new object, then the same object again: the key check must match what was stored.
    for (flag, consistent) in [
        ("--new-key", "consistent=new"),
        ("--key", "consistent=true"),
    ] {
        let key = format!("volume:{VOL}");
        let (child, rx) = ctx.start(&[
            "request", "--kind", "open", flag, &key, "--agent", "claude", "--cmd", "npm test",
        ]);
        let req = ctx.next_request(&[]).await;
        assert_eq!(req.ctx().unwrap().agent.as_deref(), Some("claude"));
        let sealed = seal_reply(
            Some(ctx.root.clone()),
            &ctx.keys,
            &req,
            Decision::Session {
                place: Place::Trusted,
            },
        )
        .unwrap();
        ctx.answer(&req, sealed).await;
        let (code, lines) = finish(child, rx).await;
        assert_eq!(code, 0, "{lines:?}");
        assert!(has(&lines, consistent), "{lines:?}");
        assert!(has(&lines, "REPLY ok=true"), "{lines:?}");
        assert!(has(&lines, "grant=session"));
    }

    // `unseal --all` in two parts with the number match: the plan signature checks out.
    let key = format!("volume:{VOL}");
    let plan_vol = format!("volume:safe:volume:{VOL}");
    let (child, mut rx) = ctx.start(&[
        "request",
        "--kind",
        "unseal",
        "--all",
        "--match",
        "--parts",
        "2",
        "--plan",
        "secrets:store",
        "--plan",
        &plan_vol,
        "--plan",
        "pairing:dev@mbp.example.com",
        "--key",
        &key,
    ]);
    let assembler = PlanAssembler::new();
    let first = ctx.next_request(&[]).await;
    assert!(assembler.add(first.clone()).unwrap().is_none());
    ctx.answer(&first, seal_plan_part_reply(&ctx.keys, &first).unwrap())
        .await;
    let second = ctx.next_request(&[first.id()]).await;
    let plan = assembler.add(second.clone()).unwrap().unwrap();
    assert!(plan.all && plan.complete);
    assert_eq!(second.level(), 3);
    let mut early = Vec::new();
    let number = loop {
        let l = rx.recv().await.unwrap();
        if let Some(n) = l.strip_prefix("NUMBER ") {
            break n.parse::<u32>().unwrap();
        }
        early.push(l);
    };
    assert!(second.match_choices().contains(&number));
    assert!(second.check_match(number));
    let not_before = fake_machine::now_ms();
    let sealed = seal_reply(
        Some(ctx.root.clone()),
        &ctx.keys,
        &second,
        Decision::Plan {
            place: Place::Trusted,
            not_before,
        },
    )
    .unwrap();
    ctx.answer(&second, sealed).await;
    let (code, lines) = finish(child, rx).await;
    let lines = [early, lines].concat();
    assert_eq!(code, 0, "{lines:?}");
    assert!(has(&lines, "PART 1 ack=1"), "{lines:?}");
    assert!(has(&lines, "plan_sig=valid"), "{lines:?}");
    assert!(has(&lines, "grant=plan"));
    assert!(has(&lines, "consistent=true"));

    // Deny an own-approval request: exit code 2.
    let (child, rx) = ctx.start(&["request", "--kind", "own", "--key", &key]);
    let req = ctx.next_request(&[first.id(), second.id()]).await;
    ctx.answer(
        &req,
        seal_reply(None, &ctx.keys, &req, Decision::Deny).unwrap(),
    )
    .await;
    let (code, lines) = finish(child, rx).await;
    assert_eq!(code, 2, "{lines:?}");
    assert!(has(&lines, "REPLY ok=false err=declined"));

    let (code, out) = ctx.run(&["show"]).await;
    assert_eq!(code, 0);
    assert!(
        out.contains(&format!("OBJECT volume:{VOL} words=qHWf")),
        "{out}"
    );
    let _ = std::fs::remove_dir_all(&ctx.home);
}
