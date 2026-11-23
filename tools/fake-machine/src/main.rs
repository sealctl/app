//! `fake-machine`: pairs with the phone app and sends sealed requests like a sealctl machine.
//! It never prints a key; it prints key checks and whether they match what it stored.

use std::io::Write;
use std::path::PathBuf;
use std::process::ExitCode;
use std::time::Duration;

use anyhow::{anyhow, bail, Context, Result};
use clap::{Parser, Subcommand};
use fake_machine::{
    b64u, b64u_fixed, next_json, now_ms, random16, send_text, MachineState, Object, Relay, Signer,
    DEFAULT_RELAY,
};
use sealctl_core::channel::{open_message, seal_status};
use sealctl_core::pairing::{verify_move_proof, verify_pairing_proof, PairingLink};
use sealctl_core::plan::{plan_hash, verify_plan_signature};
use sealctl_core::request::{new_request_id, seal_request, SealedRequest};
use sealctl_core::wire::{
    AgentUse, Handback, HandbackItem, LogEntry, MachineStatus, ObjectFacts, PlanBody, PlanItem,
    ReplyBody, Repository, RequestBody, RequestContext, RequestItem, SessionState, Subject,
};
use sealctl_core::{key_check, MachineKeys};
use serde_json::json;

#[derive(Parser)]
#[command(about = "A fake sealctl machine for testing the phone app")]
struct Cli {
    /// Where the machine keeps its keys and pairing.
    #[arg(
        long,
        env = "FAKE_MACHINE_HOME",
        default_value = ".fake-machine",
        global = true
    )]
    home: PathBuf,
    /// Relay origin.
    #[arg(long, env = "SEALCTL_RELAY", default_value = DEFAULT_RELAY, global = true)]
    relay: String,
    #[command(subcommand)]
    cmd: Cmd,
}

#[derive(Subcommand)]
enum Cmd {
    /// New machine keys, a pairing QR code, then wait for the phone.
    Pair {
        #[arg(long, default_value = "dev@mbp.example.com")]
        name: String,
        #[arg(long, default_value = "macOS 26")]
        os: String,
        #[arg(long)]
        model: Option<String>,
        /// Raw hardware id; the link carries its hint.
        #[arg(long)]
        hint_raw: Option<String>,
        /// Also write the link to this file.
        #[arg(long)]
        link_file: Option<PathBuf>,
        /// Print the link and exit without waiting.
        #[arg(long)]
        no_wait: bool,
        /// How long to wait for the phone, seconds.
        #[arg(long, default_value_t = 600)]
        wait_secs: u64,
    },
    /// Waits for the phone to register a link made by `pair --no-wait`.
    PairWait {
        #[arg(long, default_value_t = 600)]
        wait_secs: u64,
    },
    /// Sends one request and waits for the reply.
    Request(Box<RequestArgs>),
    /// Puts a sealed status on the machine channel.
    Status(StatusArgs),
    /// Listens on the machine socket and prints each message.
    Listen {
        #[arg(long, default_value_t = 60)]
        secs: u64,
        /// Stop after this many messages.
        #[arg(long)]
        count: Option<usize>,
    },
    /// Delayed approvals: `list` or `cancel <id>`.
    Delayed {
        action: String,
        /// Request ids are base64url and can start with `-`.
        #[arg(allow_hyphen_values = true)]
        id: Option<String>,
    },
    /// Unpairs this machine and forgets the phone.
    Unpair,
    /// Prints the machine id, tag and paired phone.
    Show,
}

#[derive(clap::Args)]
struct RequestArgs {
    #[arg(long)]
    kind: String,
    #[arg(long)]
    agent: Option<String>,
    #[arg(long)]
    repo_id: Option<String>,
    #[arg(long)]
    repo_name: Option<String>,
    #[arg(long, default_value = "")]
    cmd: String,
    #[arg(long, default_value = "")]
    cwd: String,
    /// `kind:name`, e.g. `secret:OPENAI_API_KEY`.
    #[arg(long)]
    subject: Option<String>,
    /// Secret names, comma separated.
    #[arg(long, value_delimiter = ',')]
    names: Vec<String>,
    /// `purpose:id` of an object; sends its stored words and check when known.
    #[arg(long = "key")]
    keys: Vec<String>,
    /// `purpose:id` of a new object (no words or check).
    #[arg(long = "new-key")]
    new_keys: Vec<String>,
    /// `agent:repo:NAME1+NAME2`.
    #[arg(long = "use")]
    uses: Vec<String>,
    #[arg(long = "match")]
    has_match: bool,
    #[arg(long)]
    lvl: Option<u32>,
    #[arg(long)]
    old: Option<String>,
    #[arg(long)]
    work: Option<u64>,
    /// Plan item `kind:name[:purpose:id]`.
    #[arg(long = "plan")]
    plan: Vec<String>,
    #[arg(long)]
    all: bool,
    #[arg(long, default_value_t = 1)]
    parts: u32,
    #[arg(long, default_value_t = 300)]
    ttl: u64,
    #[arg(long, default_value_t = 330)]
    timeout_secs: u64,
    #[command(flatten)]
    status: StatusArgs,
    /// `kind:name:to:state` of a hand-back report item.
    #[arg(long = "handback")]
    handback: Vec<String>,
    #[arg(long)]
    handback_hash: Option<String>,
    #[arg(long, default_value = "")]
    run: String,
}

#[derive(clap::Args, Clone)]
struct StatusArgs {
    /// `locked`, `open` or `waiting`.
    #[arg(long)]
    state: Option<String>,
    #[arg(long)]
    left: Option<u64>,
    /// Log entry `command:NAME1+NAME2[:agent[:repo]]`.
    #[arg(long = "log")]
    log: Vec<String>,
    /// Include the stored objects as inventory.
    #[arg(long)]
    inventory: bool,
}

const OK: u8 = 0;
const ERROR: u8 = 1;
const REFUSED: u8 = 2;
const EXPIRED: u8 = 3;
const CANCELLED: u8 = 4;

#[tokio::main]
async fn main() -> ExitCode {
    let cli = Cli::parse();
    match run(cli).await {
        Ok(code) => ExitCode::from(code),
        Err(e) => {
            eprintln!("fake-machine: {e:#}");
            ExitCode::from(ERROR)
        }
    }
}

async fn run(cli: Cli) -> Result<u8> {
    let relay = Relay::new(&cli.relay);
    match cli.cmd {
        Cmd::Pair {
            name,
            os,
            model,
            hint_raw,
            link_file,
            no_wait,
            wait_secs,
        } => {
            let keys = MachineKeys::generate()?;
            let code = random16()?;
            let hint = hint_raw
                .as_deref()
                .map(sealctl_core::machine::hardware_hint);
            let expires = now_ms() / 1000 + 600;
            let origin = cli.relay.trim_end_matches('/').to_owned();
            let link = PairingLink {
                machine: keys.public(),
                machine_box: keys.box_public(),
                code: &code,
                name: &name,
                os: &os,
                model: model.as_deref(),
                hint: hint.as_deref(),
                expires,
                relay: Some(&origin),
            }
            .link();
            let state = MachineState {
                keys: b64u(&keys.to_bytes()),
                name,
                os,
                model,
                hint,
                relay: origin,
                ..MachineState::default()
            };
            state.save(&cli.home)?;
            fake_machine::write_private(&cli.home.join("pairing-code"), b64u(&code).as_bytes())?;
            if let Some(f) = link_file {
                std::fs::write(f, &link)?;
            }
            print_qr(&link);
            println!("LINK {link}");
            println!(
                "MACHINE {} tag={}",
                keys.id(),
                sealctl_core::machine::tag(keys.public())
            );
            std::io::stdout().flush()?;
            if no_wait {
                return Ok(OK);
            }
            pair_wait(&relay, &cli.home, wait_secs).await
        }
        Cmd::PairWait { wait_secs } => pair_wait(&relay, &cli.home, wait_secs).await,
        Cmd::Request(args) => request(&relay, &cli.home, *args).await,
        Cmd::Status(args) => {
            let mut st = MachineState::load(&cli.home)?;
            let keys = st.machine_keys()?;
            let phone = st.phone_public()?;
            st.status_seq += 1;
            let status = MachineStatus {
                version: 1,
                time: now_ms(),
                seq: st.status_seq,
                state: session_state(&args),
                log: log_entries(&args.log),
                inventory: if args.inventory {
                    inventory(&st)
                } else {
                    Vec::new()
                },
                migrate: None,
            };
            let sealed = seal_status(&keys, &phone, &status)?;
            let path = format!("/v1/phones/{}/machines/{}/status", phone.id(), keys.id());
            let (code, body) = relay
                .call(
                    &Signer::Machine(&keys),
                    "PUT",
                    &path,
                    Some(&json!({ "sealed": sealed })),
                )
                .await?;
            st.save(&cli.home)?;
            println!("STATUS seq={} http={code} {body}", st.status_seq);
            Ok(if code == 200 { OK } else { ERROR })
        }
        Cmd::Listen { secs, count } => listen(&relay, &cli.home, secs, count).await,
        Cmd::Delayed { action, id } => {
            let st = MachineState::load(&cli.home)?;
            let keys = st.machine_keys()?;
            let phone = st.phone.clone().ok_or(anyhow!("not paired"))?;
            let (method, path) = match (action.as_str(), id) {
                ("list", _) => ("GET", format!("/v1/phones/{phone}/delayed")),
                ("cancel", Some(id)) => ("POST", format!("/v1/phones/{phone}/delayed/{id}/cancel")),
                ("get", Some(id)) => ("GET", format!("/v1/phones/{phone}/delayed/{id}")),
                _ => bail!("usage: delayed list | delayed get <id> | delayed cancel <id>"),
            };
            let (code, mut body) = relay
                .call(&Signer::Machine(&keys), method, &path, None)
                .await?;
            if let Some(o) = body.as_object_mut() {
                if o.remove("sealed").is_some() {
                    o.insert("sealed".into(), json!("<sealed reply>"));
                }
            }
            println!("DELAYED http={code} {body}");
            Ok(if code == 200 { OK } else { ERROR })
        }
        Cmd::Unpair => {
            let mut st = MachineState::load(&cli.home)?;
            let keys = st.machine_keys()?;
            let phone = st.phone.clone().ok_or(anyhow!("not paired"))?;
            let path = format!("/v1/phones/{phone}/machines/{}", keys.id());
            let (code, body) = relay
                .call(&Signer::Machine(&keys), "DELETE", &path, None)
                .await?;
            println!("UNPAIR http={code} {body}");
            st.phone = None;
            st.phone_box = None;
            st.save(&cli.home)?;
            Ok(if code == 200 || code == 404 {
                OK
            } else {
                ERROR
            })
        }
        Cmd::Show => {
            let st = MachineState::load(&cli.home)?;
            let keys = st.machine_keys()?;
            println!(
                "MACHINE {} tag={} name={} relay={} phone={}",
                keys.id(),
                sealctl_core::machine::tag(keys.public()),
                st.name,
                st.relay,
                st.phone.as_deref().unwrap_or("none")
            );
            for o in &st.objects {
                println!(
                    "OBJECT {}:{} words={} check={}",
                    o.purpose,
                    o.id,
                    o.words.as_deref().unwrap_or("-"),
                    o.check.as_deref().unwrap_or("-")
                );
            }
            Ok(OK)
        }
    }
}

fn print_qr(link: &str) {
    match qrcode::QrCode::with_error_correction_level(link, qrcode::EcLevel::M) {
        Ok(code) => {
            let image = code
                .render::<qrcode::render::unicode::Dense1x2>()
                .dark_color(qrcode::render::unicode::Dense1x2::Light)
                .light_color(qrcode::render::unicode::Dense1x2::Dark)
                .quiet_zone(true)
                .build();
            eprintln!("{image}");
        }
        Err(e) => eprintln!("(no QR code: {e})"),
    }
}

async fn pair_wait(relay: &Relay, home: &std::path::Path, wait_secs: u64) -> Result<u8> {
    let mut st = MachineState::load(home)?;
    let keys = st.machine_keys()?;
    let code: [u8; 16] = b64u_fixed(std::fs::read_to_string(home.join("pairing-code"))?.trim())?;
    let path = format!("/v1/machines/{}", keys.id());
    let deadline = std::time::Instant::now() + Duration::from_secs(wait_secs);
    eprintln!("Waiting for the phone to scan the code…");
    loop {
        let (status, body) = relay
            .call(&Signer::Machine(&keys), "GET", &path, None)
            .await?;
        if status == 200 {
            let phone = body["phone"].as_str().unwrap_or_default().to_owned();
            let proof = body["proof"].as_str().unwrap_or_default().to_owned();
            let p: [u8; 32] = b64u_fixed(&phone)?;
            let x = verify_pairing_proof(&code, keys.public(), &p, &proof).map_err(|_| {
                anyhow!("This pairing did not come from your phone. Run pair again.")
            })?;
            st.phone = Some(phone.clone());
            st.phone_box = Some(b64u(&x));
            st.save(home)?;
            let _ = std::fs::remove_file(home.join("pairing-code"));
            println!("PAIRED phone={phone}");
            return Ok(OK);
        }
        if status != 404 {
            bail!("relay answered {status} {body}");
        }
        if std::time::Instant::now() > deadline {
            println!("TIMEOUT");
            return Ok(EXPIRED);
        }
        tokio::time::sleep(Duration::from_secs(2)).await;
    }
}

/// After `moved` or `403`: looks the machine up and follows a move proof to a new phone key.
async fn follow_move(relay: &Relay, home: &std::path::Path, st: &mut MachineState) -> Result<bool> {
    let keys = st.machine_keys()?;
    let (status, body) = relay
        .call(
            &Signer::Machine(&keys),
            "GET",
            &format!("/v1/machines/{}", keys.id()),
            None,
        )
        .await?;
    if status != 200 {
        return Ok(false);
    }
    let new = body["phone"].as_str().unwrap_or_default().to_owned();
    let proof = body["proof"].as_str().unwrap_or_default();
    let Some(old) = st.phone.clone() else {
        return Ok(false);
    };
    if new == old || proof.len() != 128 {
        return Ok(false);
    }
    let x = verify_move_proof(&b64u_fixed(&old)?, &b64u_fixed(&new)?, keys.public(), proof)
        .map_err(|_| anyhow!("bad move proof"))?;
    st.old_phone = Some(old);
    st.phone = Some(new.clone());
    st.phone_box = Some(b64u(&x));
    st.save(home)?;
    println!("MOVED phone={new}");
    Ok(true)
}

fn split_key(text: &str) -> Result<(String, String)> {
    let (p, i) = text
        .split_once(':')
        .ok_or(anyhow!("expected purpose:id, got {text}"))?;
    Ok((p.to_owned(), i.to_owned()))
}

fn object_kind(purpose: &str) -> &str {
    if purpose == "secrets" {
        "store"
    } else {
        purpose
    }
}

fn request_item(st: &MachineState, purpose: &str, id: &str, known: bool) -> RequestItem {
    let stored = known.then(|| st.object(purpose, id)).flatten();
    RequestItem {
        purpose: purpose.to_owned(),
        id: id.to_owned(),
        words: stored.and_then(|o| o.words.clone()),
        check: stored.and_then(|o| o.check.clone()),
        object: Some(ObjectFacts {
            kind: object_kind(purpose).to_owned(),
            path: format!("~/.fake-machine/{purpose}/{id}"),
            size: 14_336,
        }),
    }
}

fn inventory(st: &MachineState) -> Vec<RequestItem> {
    st.objects
        .iter()
        .map(|o| request_item(st, &o.purpose, &o.id, true))
        .collect()
}

fn session_state(args: &StatusArgs) -> Option<SessionState> {
    args.state.as_ref().map(|s| SessionState {
        session: s.clone(),
        left: args.left,
        stop: (s == "open").then(|| now_ms() + 14 * 3_600_000),
        place: None,
        busy: Vec::new(),
    })
}

fn log_entries(specs: &[String]) -> Vec<LogEntry> {
    specs
        .iter()
        .map(|s| {
            let mut parts = s.splitn(4, ':');
            let command = parts.next().unwrap_or_default().to_owned();
            let names = parts
                .next()
                .unwrap_or_default()
                .split('+')
                .filter(|n| !n.is_empty())
                .map(str::to_owned)
                .collect();
            LogEntry {
                time: now_ms(),
                agent: parts.next().map(str::to_owned),
                repository: parts.next().map(str::to_owned),
                command,
                names,
                own: false,
            }
        })
        .collect()
}

fn build_body(st: &MachineState, a: &RequestArgs) -> Result<RequestBody> {
    let subject = match &a.subject {
        Some(s) => {
            let (k, n) = s.split_once(':').ok_or(anyhow!("--subject is kind:name"))?;
            Some(Subject {
                kind: k.into(),
                name: n.into(),
            })
        }
        None => None,
    };
    let repo = a.repo_id.as_ref().map(|id| Repository {
        id: id.clone(),
        name: a
            .repo_name
            .clone()
            .unwrap_or_else(|| id.rsplit('/').next().unwrap_or(id).to_owned()),
    });
    let mut keys = Vec::new();
    for k in &a.keys {
        let (p, i) = split_key(k)?;
        keys.push(request_item(st, &p, &i, true));
    }
    for k in &a.new_keys {
        let (p, i) = split_key(k)?;
        keys.push(request_item(st, &p, &i, false));
    }
    let uses = a
        .uses
        .iter()
        .map(|u| {
            let mut parts = u.splitn(3, ':');
            let agent = parts.next().unwrap_or_default().to_owned();
            let repository = parts.next().unwrap_or_default().to_owned();
            let names = parts
                .next()
                .unwrap_or_default()
                .split('+')
                .map(str::to_owned)
                .collect();
            AgentUse {
                agent,
                repository,
                names,
            }
        })
        .collect();
    let mut body = RequestBody {
        v: 1,
        t: now_ms(),
        why: a.kind.clone(),
        lvl: a.lvl,
        ot: None,
        has_match: a.has_match,
        ctx: Some(RequestContext {
            agent: a.agent.clone(),
            repo,
            command: a.cmd.clone(),
            cwd: a.cwd.clone(),
            user: st.name.clone(),
            subject,
            names: a.names.clone(),
        }),
        keys,
        uses,
        work: a.work,
        old: a.old.clone(),
        ..RequestBody::default()
    };
    if a.kind == "report" {
        body.ctx = None;
        body.seq = Some(st.status_seq + 1);
        body.state = session_state(&a.status);
        body.log = log_entries(&a.status.log);
        if a.status.inventory {
            body.inv = inventory(st);
        }
        if !a.handback.is_empty() {
            let items = a
                .handback
                .iter()
                .map(|h| {
                    let f: Vec<&str> = h.splitn(4, ':').collect();
                    HandbackItem {
                        kind: f.first().copied().unwrap_or_default().into(),
                        name: f.get(1).copied().unwrap_or_default().into(),
                        to: f.get(2).copied().unwrap_or_default().into(),
                        state: f.get(3).copied().unwrap_or("done").into(),
                    }
                })
                .collect();
            body.handback = Some(Handback {
                hash: a
                    .handback_hash
                    .clone()
                    .or_else(|| st.last_plan.clone())
                    .unwrap_or_default(),
                items,
                run: a.run.clone(),
            });
        }
    }
    Ok(body)
}

fn plan_items(specs: &[String]) -> Result<Vec<PlanItem>> {
    specs
        .iter()
        .map(|s| {
            let f: Vec<&str> = s.split(':').collect();
            match f.as_slice() {
                [k, n] => Ok(PlanItem {
                    kind: (*k).into(),
                    name: (*n).into(),
                    purpose: None,
                    id: None,
                }),
                [k, n, p, i] => Ok(PlanItem {
                    kind: (*k).into(),
                    name: (*n).into(),
                    purpose: Some((*p).into()),
                    id: Some((*i).into()),
                }),
                _ => bail!("--plan is kind:name or kind:name:purpose:id, got {s}"),
            }
        })
        .collect()
}

enum Outcome {
    Reply(String),
    Delayed(String, u64),
    Expired,
    Error(String),
}

/// Sends one sealed request on its own wait socket and waits for what comes back.
async fn send_one(
    relay: &Relay,
    keys: &MachineKeys,
    phone: &str,
    sent: &SealedRequest,
    ttl: u64,
    timeout: Duration,
) -> Result<Outcome> {
    let mut ws = relay
        .socket(&Signer::Machine(keys), &format!("/v1/phones/{phone}/wait"))
        .await?;
    send_text(
        &mut ws,
        &json!({"type": "request", "id": sent.id, "sealed": sent.sealed, "ttl": ttl}).to_string(),
    )
    .await?;
    let deadline = tokio::time::Instant::now() + timeout;
    let mut expires = None;
    loop {
        let until = expires
            .map(|e: u64| {
                tokio::time::Instant::now()
                    + Duration::from_millis(e.saturating_sub(now_ms()) + 2000)
            })
            .map_or(deadline, |t| t.min(deadline));
        let msg = match next_json(&mut ws, until).await {
            Ok(Some(m)) => m,
            Ok(None) => return Ok(Outcome::Error("socket closed".into())),
            // Only the deadline is an expiry; a socket failure is an error.
            Err(_) if tokio::time::Instant::now() >= until => return Ok(Outcome::Expired),
            Err(e) => return Ok(Outcome::Error(format!("socket: {e}"))),
        };
        match msg["type"].as_str().unwrap_or_default() {
            "queued" => {
                expires = msg["expires"].as_u64();
                eprintln!("queued, expires at {}", expires.unwrap_or(0));
            }
            "reply" => {
                return Ok(Outcome::Reply(
                    msg["sealed"].as_str().unwrap_or_default().to_owned(),
                ))
            }
            "delayed" => {
                return Ok(Outcome::Delayed(
                    msg["id"].as_str().unwrap_or_default().to_owned(),
                    msg["releaseAt"].as_u64().unwrap_or(0),
                ))
            }
            "expired" => return Ok(Outcome::Expired),
            "error" => {
                return Ok(Outcome::Error(
                    msg["error"].as_str().unwrap_or("error").to_owned(),
                ))
            }
            _ => {}
        }
    }
}

async fn request(relay: &Relay, home: &std::path::Path, a: RequestArgs) -> Result<u8> {
    let mut st = MachineState::load(home)?;
    let keys = st.machine_keys()?;
    let mut body = build_body(&st, &a)?;
    let mut parts: Vec<RequestBody> = Vec::new();
    if a.kind == "unseal" {
        let items = plan_items(&a.plan)?;
        let h = b64u(&plan_hash(&keys.id(), &items));
        st.last_plan = Some(h.clone());
        let n = a.parts.max(1).min(items.len().max(1) as u32);
        let per = items.len().div_ceil(n as usize).max(1);
        let chunks: Vec<Vec<PlanItem>> = if items.is_empty() {
            vec![Vec::new()]
        } else {
            items.chunks(per).map(<[PlanItem]>::to_vec).collect()
        };
        let total = chunks.len() as u32;
        for (idx, chunk) in chunks.into_iter().enumerate() {
            let last = idx as u32 + 1 == total;
            let mut b = body.clone();
            b.plan = Some(PlanBody {
                all: a.all,
                h: h.clone(),
                items: chunk,
                n: (total > 1).then_some(total),
                i: (total > 1).then_some(idx as u32 + 1),
            });
            if !last {
                b.keys = Vec::new();
                b.has_match = false;
            }
            parts.push(b);
        }
    } else {
        parts.push(std::mem::take(&mut body));
    }

    let total = parts.len();
    for (idx, part) in parts.into_iter().enumerate() {
        let last = idx + 1 == total;
        let mut retried = false;
        loop {
            let phone_pub = st.phone_public()?;
            let phone = st.phone.clone().expect("paired");
            let id = new_request_id()?;
            let sent = seal_request(&keys, &phone_pub, &id, part.clone())?;
            if let Some(n) = sent.number {
                println!("NUMBER {n}");
                std::io::stdout().flush()?;
                eprintln!("\n    The number on this machine is:  {n}\n");
            }
            eprintln!("sent {} request {id}", part.why);
            let outcome = send_one(
                relay,
                &keys,
                &phone,
                &sent,
                a.ttl,
                Duration::from_secs(a.timeout_secs),
            )
            .await;
            let outcome = match outcome {
                Err(e) if e.to_string().contains(" 403 ") && !retried => {
                    retried = true;
                    if follow_move(relay, home, &mut st).await? {
                        continue;
                    }
                    return Err(e);
                }
                o => o?,
            };
            let sealed = match outcome {
                Outcome::Reply(s) => s,
                Outcome::Expired => {
                    println!("REPLY ok=false err=expired");
                    st.save(home)?;
                    return Ok(EXPIRED);
                }
                Outcome::Error(e) if (e == "moved" || e == "unpaired") && !retried => {
                    retried = true;
                    if follow_move(relay, home, &mut st).await? {
                        continue;
                    }
                    println!("REPLY ok=false err={e}");
                    return Ok(ERROR);
                }
                Outcome::Error(e) => {
                    println!("REPLY ok=false err={e}");
                    return Ok(ERROR);
                }
                Outcome::Delayed(did, release_at) => {
                    println!("DELAYED id={did} releaseAt={release_at}");
                    std::io::stdout().flush()?;
                    match wait_delayed(relay, &keys, &phone, &did, release_at).await? {
                        Ok(s) => s,
                        Err(code) => {
                            st.save(home)?;
                            return Ok(code);
                        }
                    }
                }
            };
            let p: [u8; 32] = b64u_fixed(&phone)?;
            let reply = sent
                .open_reply(keys.public(), &p, &sealed)
                .map_err(|e| anyhow!("bad_reply: {e}"))?;
            if !last {
                println!(
                    "PART {} ack={}",
                    idx + 1,
                    reply.part.map_or("-".into(), |n| n.to_string())
                );
                if !reply.ok {
                    return finish(&mut st, home, &sent, &reply, &p, &keys);
                }
                break;
            }
            return finish(&mut st, home, &sent, &reply, &p, &keys);
        }
    }
    Ok(OK)
}

/// Polls a delayed approval until the machine can fetch it (`Ok(sealed)`) or it is cancelled.
async fn wait_delayed(
    relay: &Relay,
    keys: &MachineKeys,
    phone: &str,
    id: &str,
    release_at: u64,
) -> Result<std::result::Result<String, u8>> {
    let path = format!("/v1/phones/{phone}/delayed/{id}");
    let give_up = release_at + 15 * 60_000;
    loop {
        let wait = release_at.saturating_sub(now_ms()).clamp(1000, 5000);
        tokio::time::sleep(Duration::from_millis(wait)).await;
        let (code, body) = relay
            .call(&Signer::Machine(keys), "GET", &path, None)
            .await?;
        if code == 404 {
            println!("REPLY ok=false err=gone");
            return Ok(Err(EXPIRED));
        }
        if code != 200 {
            bail!("delayed answered {code} {body}");
        }
        if body["state"] == "cancelled" {
            println!("CANCELLED by={}", body["by"].as_str().unwrap_or("?"));
            return Ok(Err(CANCELLED));
        }
        if let Some(s) = body["sealed"].as_str() {
            return Ok(Ok(s.to_owned()));
        }
        if now_ms() > give_up {
            println!("REPLY ok=false err=expired");
            return Ok(Err(EXPIRED));
        }
    }
}

fn finish(
    st: &mut MachineState,
    home: &std::path::Path,
    sent: &SealedRequest,
    reply: &ReplyBody,
    phone: &[u8; 32],
    keys: &MachineKeys,
) -> Result<u8> {
    let plan_sig = match &reply.plan {
        None => "none",
        Some(ps) => {
            let ph: [u8; 32] = b64u_fixed(&ps.h).unwrap_or([0; 32]);
            if verify_plan_signature(phone, &sent.id, keys.public(), &ph, ps.nb, &ps.sig).is_ok() {
                "valid"
            } else {
                "invalid"
            }
        }
    };
    let mut key_lines = Vec::new();
    for k in &reply.keys {
        let mut line = json!({"p": k.p, "i": k.i, "err": k.err, "retired": k.retired});
        if let Some(text) = k.k.as_deref() {
            let raw: [u8; 16] = b64u_fixed(text)?;
            let check = key_check(&raw);
            let stored = st.object(&k.p, &k.i).and_then(|o| o.check.clone());
            let old_check = match k.old.as_deref() {
                Some(o) => Some(key_check(&b64u_fixed::<16>(o)?)),
                None => None,
            };
            // A rewrap or old-words reply proves itself with the old key; others with the new one.
            let consistent = match (&stored, &old_check) {
                (Some(s), Some(o)) => (s == o).to_string(),
                (Some(s), None) => (s == &check).to_string(),
                (None, _) => "new".to_owned(),
            };
            println!("KEY {}:{} check={check} consistent={consistent}", k.p, k.i);
            line["check"] = json!(check);
            line["consistent"] = json!(consistent);
            st.remember(Object {
                purpose: k.p.clone(),
                id: k.i.clone(),
                words: reply.w.clone(),
                check: Some(check),
            });
        } else if let Some(e) = &k.err {
            println!("KEY {}:{} err={e}", k.p, k.i);
        }
        key_lines.push(line);
    }
    if let Some(ack) = reply.ack {
        st.status_seq = st.status_seq.max(ack);
    }
    for m in &reply.msgs {
        println!("MESSAGE seq={} {}", m.seq, serde_json::to_string(m)?);
        st.message_seq = st.message_seq.max(m.seq);
    }
    let opt = |v: Option<String>| v.unwrap_or_else(|| "-".into());
    println!(
        "REPLY ok={} err={} grant={} place={} cap={} lvl={} w={} remember={} more={} plan_sig={plan_sig}",
        reply.ok,
        opt(reply.err.clone()),
        opt(reply.grant.clone()),
        opt(reply.place.clone()),
        opt(reply.cap.map(|c| c.to_string())),
        opt(reply.lvl.map(|c| c.to_string())),
        opt(reply.w.clone()),
        opt(reply.remember.map(|c| c.to_string())),
        opt(reply.more.map(|c| c.to_string())),
    );
    let summary = json!({
        "id": sent.id, "ok": reply.ok, "err": reply.err, "lvl": reply.lvl, "w": reply.w, "grant": reply.grant,
        "remember": reply.remember, "place": reply.place, "cap": reply.cap, "base": reply.base, "rate": reply.rate,
        "more": reply.more, "part": reply.part, "ack": reply.ack, "plan_sig": plan_sig,
        "plan_nb": reply.plan.as_ref().map(|p| p.nb), "keys": key_lines,
        "msgs": reply.msgs.len(),
    });
    println!("JSON {summary}");
    st.save(home)?;
    Ok(if reply.ok { OK } else { REFUSED })
}

async fn listen(
    relay: &Relay,
    home: &std::path::Path,
    secs: u64,
    count: Option<usize>,
) -> Result<u8> {
    let mut st = MachineState::load(home)?;
    let keys = st.machine_keys()?;
    let phone = st.phone.clone().ok_or(anyhow!("not paired"))?;
    let p: [u8; 32] = b64u_fixed(&phone)?;
    let path = format!("/v1/phones/{phone}/machines/{}/socket", keys.id());
    let mut ws = relay.socket(&Signer::Machine(&keys), &path).await?;
    println!("LISTENING");
    std::io::stdout().flush()?;
    let deadline = tokio::time::Instant::now() + Duration::from_secs(secs);
    let mut seen = 0usize;
    loop {
        let msg = match next_json(&mut ws, deadline).await {
            Ok(Some(m)) => m,
            Ok(None) => {
                println!("CLOSED");
                break;
            }
            Err(_) => break,
        };
        match msg["type"].as_str().unwrap_or_default() {
            "message" => {
                let sealed = msg["sealed"].as_str().unwrap_or_default();
                match open_message(&keys, &p, sealed) {
                    Ok(m) => {
                        let fresh = m.seq > st.message_seq;
                        st.message_seq = st.message_seq.max(m.seq);
                        let v = serde_json::to_value(&m).context("message")?;
                        println!(
                            "MESSAGE seq={} type={} fresh={fresh} {}",
                            m.seq,
                            v["type"].as_str().unwrap_or("?"),
                            v
                        );
                    }
                    Err(e) => println!("MESSAGE bad: {e}"),
                }
            }
            "error" => {
                println!("ERROR {}", msg["error"].as_str().unwrap_or("?"));
                break;
            }
            _ => println!("NOTE {msg}"),
        }
        std::io::stdout().flush()?;
        seen += 1;
        if count.is_some_and(|c| seen >= c) {
            break;
        }
    }
    st.save(home)?;
    Ok(OK)
}
