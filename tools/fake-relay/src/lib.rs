//! An in-memory sealctl relay (docs/protocol.md, Relay API), for app and machine tests.
//!
//! It implements the routes of the real relay, including the planned ones (push devices,
//! machine channel, delayed approvals, deleting a phone), checks every signature with
//! `sealctl-core`, and adds unsigned test controls under `/test/` for loopback callers only.

use std::collections::{BTreeMap, HashMap};
use std::net::{IpAddr, SocketAddr};
use std::sync::{Arc, Mutex};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use axum::body::{to_bytes, Body};
use axum::extract::ws::{CloseFrame, Message, WebSocket, WebSocketUpgrade};
use axum::extract::{ConnectInfo, FromRequestParts};
use axum::http::{HeaderMap, Method, Request, StatusCode};
use axum::response::{IntoResponse, Response};
use axum::Router;
use base64::engine::general_purpose::URL_SAFE_NO_PAD as B64U;
use base64::Engine;
use futures_util::{SinkExt, StreamExt};
use sealctl_core::relay_auth::{verify_relay_headers, RelayHeaders};
use sealctl_core::CoreError;
use serde_json::{json, Map, Value};
use tokio::sync::mpsc;

const MAX_SEALED: usize = 4096;
const MAX_TTL: u64 = 300;
const MAX_PENDING: usize = 32;
const MAX_STATE_BYTES: usize = 1 << 20;
const MAX_MACHINES: usize = 100;
const MAX_BODY: usize = 16_384;
const MAX_STATE_BODY: usize = 1_500_000;
const MAX_WS_MESSAGE: usize = 8192;
const MAX_STATUS: usize = 8192;
const MAX_MESSAGE: usize = 4096;
const MAX_HELD: usize = 16;
const HELD_MS: u64 = 24 * 3_600_000;
const MAX_DELAYED: usize = 4;
const DELAYED_KEEP_MS: u64 = 900_000;
const MAX_DEVICES: usize = 4;
const ABUSE_LIMIT: u32 = 5000;
const WINDOW_SECS: u64 = 300;

// ---------------------------------------------------------------- state ----

enum Out {
    Text(String),
    Close(u16),
}

type Tx = mpsc::UnboundedSender<Out>;

fn send(tx: &Tx, msg: &Value) {
    let _ = tx.send(Out::Text(msg.to_string()));
}

fn close_with(tx: &Tx, msg: Option<&Value>, code: u16) {
    if let Some(m) = msg {
        send(tx, m);
    }
    let _ = tx.send(Out::Close(code));
}

struct MachineRecord {
    name: String,
    os: Option<String>,
    model: Option<String>,
    paired_at: u64,
}

struct Device {
    platform: String,
    token: String,
    sandbox: bool,
    updated: u64,
}

struct Delayed {
    machine: Option<String>,
    sealed: Option<String>,
    created: u64,
    release_at: u64,
    expires: u64,
    cancelled: Option<String>,
}

struct Pending {
    id: String,
    sealed: String,
    created: u64,
    expires: u64,
}

struct Wait {
    machine: String,
    ip: IpAddr,
    tx: Tx,
    pending: Option<Pending>,
}

struct PhoneSock {
    ip: IpAddr,
    tx: Tx,
}

#[derive(Default)]
struct Phone {
    machines: BTreeMap<String, MachineRecord>,
    seen: HashMap<String, u64>,
    state: Option<(u64, String)>,
    devices: BTreeMap<String, Device>,
    status: HashMap<String, (String, u64)>,
    held: HashMap<String, Vec<(String, u64)>>,
    delayed: BTreeMap<String, Delayed>,
    waits: BTreeMap<u64, Wait>,
    sockets: BTreeMap<u64, PhoneSock>,
    machine_sockets: HashMap<String, (u64, Tx)>,
    calls: (u64, u32),
    days_used: u64,
    last_day: u64,
    moved_to: Option<String>,
    phone_ip: Option<IpAddr>,
}

struct Fail {
    status: u16,
    error: String,
    path: Option<String>,
    times: u32,
    extra: Map<String, Value>,
}

#[derive(Default)]
struct Relay {
    phones: HashMap<String, Phone>,
    index: HashMap<String, (String, Option<String>)>,
    offset_secs: i64,
    near: Option<bool>,
    fails: Vec<Fail>,
    replies: Vec<Value>,
    pushes: Vec<Value>,
    next_conn: u64,
}

impl Relay {
    fn now_ms(&self) -> u64 {
        let sys = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_or(0, |d| d.as_millis() as i64);
        (sys + self.offset_secs * 1000).max(0) as u64
    }

    fn conn(&mut self) -> u64 {
        self.next_conn += 1;
        self.next_conn
    }

    fn push_all(&mut self, phone: &str, kind: &str, id: &str, expires: u64) {
        let Some(p) = self.phones.get(phone) else {
            return;
        };
        let entries: Vec<Value> = p
            .devices
            .iter()
            .map(|(device, d)| {
                json!({"phone": phone, "device": device, "platform": d.platform, "token": d.token,
                       "type": kind, "id": id, "expires": expires})
            })
            .collect();
        self.pushes.extend(entries);
    }
}

type Shared = Arc<Mutex<Relay>>;

// ------------------------------------------------------------- helpers ----

fn is_b64u(s: &str, max: usize) -> bool {
    !s.is_empty()
        && s.len() <= max
        && s.bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
}

fn is_key_id(s: &str) -> bool {
    s.len() == 43 && is_b64u(s, 43)
}

fn is_request_id(s: &str) -> bool {
    s.len() == 22 && is_b64u(s, 22)
}

fn short_text(v: Option<&Value>) -> Result<Option<String>, ()> {
    match v {
        None | Some(Value::Null) => Ok(None),
        Some(Value::String(s)) if s.chars().count() <= 200 => Ok(Some(s.clone())),
        _ => Err(()),
    }
}

fn utc_day(ms: u64) -> u64 {
    ms / 86_400_000
}

fn ok(body: Value) -> Response {
    reply(StatusCode::OK, body)
}

fn reply(status: StatusCode, body: Value) -> Response {
    (
        status,
        [("content-type", "application/json")],
        body.to_string(),
    )
        .into_response()
}

fn fail(status: u16, error: &str) -> Response {
    fail_with(status, error, Map::new())
}

fn fail_with(status: u16, error: &str, extra: Map<String, Value>) -> Response {
    let mut body = Map::new();
    body.insert("error".into(), Value::String(error.into()));
    let retry = extra.get("retryAfter").and_then(Value::as_u64);
    body.extend(extra);
    let status = StatusCode::from_u16(status).unwrap_or(StatusCode::INTERNAL_SERVER_ERROR);
    let mut res = reply(status, Value::Object(body));
    if let Some(r) = retry {
        res.headers_mut()
            .insert("retry-after", r.to_string().parse().expect("digits"));
    }
    res
}

fn extra(pairs: &[(&str, Value)]) -> Map<String, Value> {
    pairs
        .iter()
        .map(|(k, v)| (k.to_string(), v.clone()))
        .collect()
}

// --------------------------------------------------------------- router ----

/// The relay's routes on a fresh in-memory state.
pub fn app() -> Router {
    let shared: Shared = Arc::new(Mutex::new(Relay::default()));
    Router::new().fallback(move |req| handle(shared.clone(), req))
}

/// Binds `addr` (e.g. `127.0.0.1:0`) and serves in the background; returns the bound address.
pub async fn spawn(addr: &str) -> std::io::Result<SocketAddr> {
    let listener = tokio::net::TcpListener::bind(addr).await?;
    let local = listener.local_addr()?;
    tokio::spawn(async move {
        let _ = axum::serve(
            listener,
            app().into_make_service_with_connect_info::<SocketAddr>(),
        )
        .await;
    });
    Ok(local)
}

/// Serves on `addr` until the process ends.
pub async fn serve(addr: &str) -> std::io::Result<()> {
    let listener = tokio::net::TcpListener::bind(addr).await?;
    eprintln!("fake-relay listening on http://{}", listener.local_addr()?);
    axum::serve(
        listener,
        app().into_make_service_with_connect_info::<SocketAddr>(),
    )
    .await
}

enum Route {
    Health,
    Lookup(String),
    DeletePhone,
    AddMachine,
    ListMachines,
    RemoveMachine(String),
    PutStatus(String),
    PostMessage(String),
    MachineSocket(String),
    ListStatus,
    Wait,
    Socket,
    ListRequests,
    Reply(String),
    AddDelayed,
    ListDelayed,
    GetDelayed(String),
    CancelDelayed(String),
    FinishDelayed(String),
    GetState,
    PutState,
    Licence,
    Checkout,
    Claim,
    Move,
    ListPush,
    PutPush(String),
    DeletePush(String),
    TestPush(String),
}

fn route(method: &Method, segs: &[&str]) -> Option<(Option<String>, Route)> {
    use Route::*;
    let m = method.as_str();
    match segs {
        ["v1", "health"] if m == "GET" => return Some((None, Health)),
        ["v1", "machines", machine] if m == "GET" => {
            return Some((None, Lookup(machine.to_string())))
        }
        _ => {}
    }
    let ["v1", "phones", phone, rest @ ..] = segs else {
        return None;
    };
    let s = |x: &str| x.to_string();
    let r = match (m, rest) {
        ("DELETE", []) => DeletePhone,
        ("POST", ["machines"]) => AddMachine,
        ("GET", ["machines"]) => ListMachines,
        ("DELETE", ["machines", x]) => RemoveMachine(s(x)),
        ("PUT", ["machines", x, "status"]) => PutStatus(s(x)),
        ("POST", ["machines", x, "messages"]) => PostMessage(s(x)),
        ("GET", ["machines", x, "socket"]) => MachineSocket(s(x)),
        ("GET", ["status"]) => ListStatus,
        ("GET", ["wait"]) => Wait,
        ("GET", ["socket"]) => Socket,
        ("GET", ["requests"]) => ListRequests,
        ("POST", ["requests", x, "reply"]) => Reply(s(x)),
        ("POST", ["delayed"]) => AddDelayed,
        ("GET", ["delayed"]) => ListDelayed,
        ("GET", ["delayed", x]) => GetDelayed(s(x)),
        ("POST", ["delayed", x, "cancel"]) => CancelDelayed(s(x)),
        ("POST", ["delayed", x, "finish"]) => FinishDelayed(s(x)),
        ("GET", ["state"]) => GetState,
        ("PUT", ["state"]) => PutState,
        ("GET", ["licence"]) => Licence,
        ("POST", ["checkout"]) => Checkout,
        ("POST", ["claim"]) => Claim,
        ("POST", ["licence", "move"]) => Move,
        ("GET", ["push"]) => ListPush,
        ("PUT", ["push", x]) => PutPush(s(x)),
        ("DELETE", ["push", x]) => DeletePush(s(x)),
        ("POST", ["push", x, "test"]) => TestPush(s(x)),
        _ => return None,
    };
    Some((Some(phone.to_string()), r))
}

fn verify(
    headers: &HeaderMap,
    method: &str,
    pq: &str,
    body: &[u8],
    now_secs: u64,
) -> Result<String, &'static str> {
    let get = |n: &str| {
        headers
            .get(n)
            .and_then(|v| v.to_str().ok())
            .map(str::to_owned)
    };
    let (Some(key), Some(time), Some(signature)) = (
        get("sealctl-key"),
        get("sealctl-time"),
        get("sealctl-signature"),
    ) else {
        return Err("unsigned");
    };
    if !is_key_id(&key) {
        return Err("bad_key");
    }
    if time.is_empty() || time.len() > 12 || !time.bytes().all(|b| b.is_ascii_digit()) {
        return Err("bad_time");
    }
    let t: u64 = time.parse().map_err(|_| "bad_time")?;
    if t.abs_diff(now_secs) > WINDOW_SECS {
        return Err("clock_skew");
    }
    let h = RelayHeaders {
        key: key.clone(),
        time,
        signature,
    };
    match verify_relay_headers(&h, method, pq, body, now_secs) {
        Ok(()) => Ok(key),
        Err(CoreError::Expired) => Err("clock_skew"),
        Err(CoreError::BadKey) => Err("bad_key"),
        Err(_) => Err("bad_signature"),
    }
}

async fn handle(shared: Shared, req: Request<Body>) -> Response {
    let peer = req
        .extensions()
        .get::<ConnectInfo<SocketAddr>>()
        .map_or(IpAddr::from([127, 0, 0, 1]), |c| c.0.ip());
    let path = req.uri().path().to_owned();
    if path.starts_with("/test/") {
        if !peer.is_loopback() {
            return fail(403, "forbidden");
        }
        return test_route(shared, req).await;
    }
    let pq = req
        .uri()
        .path_and_query()
        .map_or(path.clone(), |p| p.as_str().to_owned());
    let method = req.method().clone();
    let segs: Vec<&str> = path.split('/').filter(|s| !s.is_empty()).collect();
    let Some((phone, route)) = route(&method, &segs) else {
        return fail(404, "not_found");
    };
    if let Route::Health = route {
        let now = shared.lock().unwrap().now_ms();
        return ok(json!({"ok": true, "env": "fake", "version": "fake", "time": now / 1000}));
    }
    // A forced failure from /test/fail.
    {
        let mut r = shared.lock().unwrap();
        if let Some(i) = r
            .fails
            .iter()
            .position(|f| f.path.as_deref().is_none_or(|p| path.contains(p)))
        {
            let f = &mut r.fails[i];
            let res = fail_with(f.status, &f.error, f.extra.clone());
            f.times = f.times.saturating_sub(1);
            if f.times == 0 {
                r.fails.remove(i);
            }
            return res;
        }
    }
    let (mut parts, body) = req.into_parts();
    let cap = if matches!(route, Route::PutState) {
        MAX_STATE_BODY
    } else {
        MAX_BODY
    };
    let Ok(body) = to_bytes(body, cap).await else {
        return fail(413, "too_large");
    };
    let now = shared.lock().unwrap().now_ms();
    let signer = match verify(&parts.headers, method.as_str(), &pq, &body, now / 1000) {
        Ok(s) => s,
        Err("clock_skew") => {
            return fail_with(401, "clock_skew", extra(&[("time", json!(now / 1000))]))
        }
        Err(e) => return fail(401, e),
    };
    let input: Value = if body.is_empty() {
        Value::Null
    } else {
        match serde_json::from_slice(&body) {
            Ok(v) => v,
            Err(_) => return fail(400, "bad_json"),
        }
    };

    if let Route::Lookup(machine) = &route {
        if !is_key_id(machine) {
            return fail(400, "bad_machine");
        }
        if &signer != machine {
            return fail(403, "forbidden");
        }
        let r = shared.lock().unwrap();
        return match r.index.get(machine) {
            Some((phone, proof)) => ok(json!({"phone": phone, "proof": proof})),
            None => fail(404, "not_paired"),
        };
    }
    let phone = phone.expect("phone routes have a phone");
    if !is_key_id(&phone) {
        return fail(404, "not_found");
    }

    let upgrade = matches!(route, Route::Wait | Route::Socket | Route::MachineSocket(_));
    if upgrade {
        let is_ws = parts
            .headers
            .get("upgrade")
            .and_then(|v| v.to_str().ok())
            .is_some_and(|v| v.eq_ignore_ascii_case("websocket"));
        if !is_ws {
            return fail(426, "websocket_required");
        }
        let ws = match WebSocketUpgrade::from_request_parts(&mut parts, &()).await {
            Ok(ws) => ws,
            Err(e) => return e.into_response(),
        };
        return upgrade_socket(shared, ws, phone, signer, route, peer);
    }

    let mut r = shared.lock().unwrap();
    dispatch(&mut r, route, &phone, &signer, input, peer)
}

#[derive(PartialEq, Clone, Copy)]
enum Role {
    Phone,
    Machine,
}

/// Authorises the signer for `phone` and charges the call against the abuse limit.
#[allow(clippy::result_large_err)]
fn enter(
    r: &mut Relay,
    phone: &str,
    signer: &str,
    allowed: &[Role],
    ip: IpAddr,
) -> Result<Role, Response> {
    let now = r.now_ms();
    let paired = r
        .phones
        .get(phone)
        .is_some_and(|p| p.machines.contains_key(signer));
    let role = if signer == phone {
        Role::Phone
    } else if paired {
        Role::Machine
    } else {
        return Err(fail(403, "forbidden"));
    };
    if !allowed.contains(&role) {
        return Err(fail(403, "forbidden"));
    }
    let p = r.phones.entry(phone.to_owned()).or_default();
    let day = utc_day(now);
    if p.calls.0 != day {
        p.calls = (day, 0);
    }
    p.calls.1 += 1;
    if p.calls.1 > ABUSE_LIMIT {
        let retry = (day + 1) * 86_400 - now / 1000;
        return Err(fail_with(
            429,
            "rate_limited",
            extra(&[("retryAfter", json!(retry)), ("scope", json!("phone"))]),
        ));
    }
    match role {
        Role::Phone => p.phone_ip = Some(ip),
        Role::Machine => {
            p.seen
                .insert(signer.to_owned(), now / 3_600_000 * 3_600_000);
        }
    }
    Ok(role)
}

fn phone_mut<'a>(r: &'a mut Relay, phone: &str) -> &'a mut Phone {
    r.phones.entry(phone.to_owned()).or_default()
}

/// Closes a machine's waits and machine socket and forgets its channel data.
fn drop_machine(p: &mut Phone, machine: &str, reason: &str) {
    let err = json!({"type": "error", "error": reason});
    p.waits.retain(|_, w| {
        if w.machine == machine {
            close_with(&w.tx, Some(&err), 1008);
            false
        } else {
            true
        }
    });
    if let Some((_, tx)) = p.machine_sockets.remove(machine) {
        close_with(&tx, Some(&err), 1008);
    }
    p.status.remove(machine);
    p.held.remove(machine);
    p.seen.remove(machine);
}

/// Pending requests; expired ones are closed with `expired` on the way, as the relay does.
fn expire_waits(p: &mut Phone, now: u64) {
    p.waits.retain(|_, w| match &w.pending {
        Some(pd) if pd.expires <= now => {
            close_with(&w.tx, Some(&json!({"type": "expired", "id": pd.id})), 1000);
            false
        }
        _ => true,
    });
}

fn live_delayed(p: &mut Phone, now: u64) {
    p.delayed.retain(|_, d| d.expires > now);
}

fn delayed_view(id: &str, d: &Delayed, now: u64) -> Value {
    let state = if d.cancelled.is_some() {
        "cancelled"
    } else if now >= d.release_at {
        "released"
    } else {
        "waiting"
    };
    let mut v = json!({"id": id, "machine": d.machine, "created": d.created, "releaseAt": d.release_at,
                       "expires": d.expires, "state": state});
    if let Some(by) = &d.cancelled {
        v["by"] = json!(by);
    }
    v
}

fn announce(p: &Phone, note: &Value) {
    for s in p.sockets.values() {
        send(&s.tx, note);
    }
    for (_, tx) in p.machine_sockets.values() {
        send(tx, note);
    }
}

fn valid_delay(v: &Value) -> Option<u64> {
    v.as_u64().filter(|d| (1..=7200).contains(d))
}

fn create_delayed(
    r: &mut Relay,
    phone: &str,
    id: &str,
    machine: Option<String>,
    sealed: Option<String>,
    delay: u64,
) -> u64 {
    let now = r.now_ms();
    let release_at = now + delay * 1000;
    let p = phone_mut(r, phone);
    p.delayed.insert(
        id.to_owned(),
        Delayed {
            machine: machine.clone(),
            sealed,
            created: now,
            release_at,
            expires: release_at + DELAYED_KEEP_MS,
            cancelled: None,
        },
    );
    announce(
        p,
        &json!({"type": "delayed", "id": id, "machine": machine, "releaseAt": release_at}),
    );
    release_at
}

fn dispatch(
    r: &mut Relay,
    route: Route,
    phone: &str,
    signer: &str,
    input: Value,
    ip: IpAddr,
) -> Response {
    use Route::*;
    let get = |k: &str| input.get(k);
    let str_of = |k: &str| input.get(k).and_then(Value::as_str).map(str::to_owned);
    let both = [Role::Phone, Role::Machine];
    let now = r.now_ms();
    macro_rules! enter {
        ($roles:expr) => {
            match enter(r, phone, signer, $roles, ip) {
                Ok(role) => role,
                Err(res) => return res,
            }
        };
    }
    match route {
        AddMachine => {
            enter!(&[Role::Phone]);
            let Some(machine) = str_of("machine").filter(|m| is_key_id(m) && m != phone) else {
                return fail(400, "bad_machine");
            };
            let Some(name) = str_of("name").filter(|n| !n.is_empty() && n.chars().count() <= 200)
            else {
                return fail(400, "bad_name");
            };
            let mut fields = Vec::new();
            for f in ["os", "model", "hint"] {
                match short_text(get(f)) {
                    Ok(v) => fields.push(v),
                    Err(()) => return fail(400, &format!("bad_{f}")),
                }
            }
            let proof = match get("proof") {
                None | Some(Value::Null) => None,
                Some(Value::String(s)) if is_b64u(s, 128) => Some(s.clone()),
                _ => return fail(400, "bad_proof"),
            };
            let p = phone_mut(r, phone);
            let known = p.machines.contains_key(&machine);
            if !known && p.machines.len() >= MAX_MACHINES {
                return fail(409, "too_many_machines");
            }
            p.machines.insert(
                machine.clone(),
                MachineRecord {
                    name,
                    os: fields[0].clone(),
                    model: fields[1].clone(),
                    paired_at: now,
                },
            );
            let count = p.machines.len();
            let previous = r.index.insert(machine.clone(), (phone.to_owned(), proof));
            if let Some((prev, _)) = previous.filter(|(prev, _)| prev != phone) {
                if let Some(pp) = r.phones.get_mut(&prev) {
                    pp.machines.remove(&machine);
                    drop_machine(pp, &machine, "moved");
                }
            }
            reply(
                if known {
                    StatusCode::OK
                } else {
                    StatusCode::CREATED
                },
                json!({"machine": machine, "machines": count}),
            )
        }
        ListMachines => {
            enter!(&[Role::Phone]);
            let p = phone_mut(r, phone);
            let list: Vec<Value> = p
                .machines
                .iter()
                .map(|(m, rec)| {
                    let mut v = json!({"machine": m, "name": rec.name, "pairedAt": rec.paired_at,
                                       "lastSeen": p.seen.get(m)});
                    if let Some(os) = &rec.os {
                        v["os"] = json!(os);
                    }
                    if let Some(model) = &rec.model {
                        v["model"] = json!(model);
                    }
                    v
                })
                .collect();
            ok(json!({"machines": list}))
        }
        RemoveMachine(machine) => {
            let role = enter!(&both);
            if role == Role::Machine && signer != machine {
                return fail(403, "forbidden");
            }
            let p = phone_mut(r, phone);
            if p.machines.remove(&machine).is_none() {
                return fail(404, "not_paired");
            }
            drop_machine(p, &machine, "unpaired");
            let count = p.machines.len();
            if r.index.get(&machine).is_some_and(|(ph, _)| ph == phone) {
                r.index.remove(&machine);
            }
            ok(json!({"machines": count}))
        }
        DeletePhone => {
            enter!(&[Role::Phone]);
            let p = r.phones.remove(phone).unwrap_or_default();
            let err = json!({"type": "error", "error": "unpaired"});
            for w in p.waits.values() {
                close_with(&w.tx, Some(&err), 1008);
            }
            for (_, tx) in p.machine_sockets.values() {
                close_with(tx, Some(&err), 1008);
            }
            for s in p.sockets.values() {
                close_with(&s.tx, None, 1000);
            }
            for m in p.machines.keys() {
                if r.index.get(m).is_some_and(|(ph, _)| ph == phone) {
                    r.index.remove(m);
                }
            }
            ok(json!({"deleted": true, "machines": p.machines.len()}))
        }
        ListRequests => {
            enter!(&[Role::Phone]);
            let near_override = r.near;
            let p = phone_mut(r, phone);
            expire_waits(p, now);
            let list: Vec<Value> = p
                .waits
                .values()
                .filter_map(|w| {
                    let pd = w.pending.as_ref()?;
                    let near = near_override.unwrap_or(w.ip == ip);
                    Some(
                        json!({"id": pd.id, "machine": w.machine, "sealed": pd.sealed,
                                "created": pd.created, "expires": pd.expires, "near": near}),
                    )
                })
                .collect();
            ok(json!({"requests": list}))
        }
        Reply(id) => {
            enter!(&[Role::Phone]);
            if !is_request_id(&id) {
                return fail(400, "bad_id");
            }
            let Some(sealed) = str_of("sealed").filter(|s| is_b64u(s, MAX_SEALED)) else {
                return fail(400, "bad_sealed");
            };
            let delay = match get("delay") {
                None | Some(Value::Null) => None,
                Some(v) => match valid_delay(v) {
                    Some(d) => Some(d),
                    None => return fail(400, "bad_delay"),
                },
            };
            let p = phone_mut(r, phone);
            expire_waits(p, now);
            let Some(conn) = p
                .waits
                .iter()
                .find(|(_, w)| w.pending.as_ref().is_some_and(|pd| pd.id == id))
                .map(|(c, _)| *c)
            else {
                return fail(404, "gone");
            };
            if delay.is_some() {
                live_delayed(p, now);
                if p.delayed.contains_key(&id) {
                    return fail(409, "duplicate_id");
                }
                if p.delayed.len() >= MAX_DELAYED {
                    return fail(429, "too_many_delayed");
                }
            }
            let w = p.waits.remove(&conn).expect("found above");
            let day = utc_day(now);
            if p.last_day != day {
                p.last_day = day;
                p.days_used += 1;
            }
            r.replies.push(
                json!({"phone": phone, "id": id, "machine": w.machine, "sealed": sealed,
                                  "delay": delay, "at": now}),
            );
            match delay {
                None => {
                    close_with(
                        &w.tx,
                        Some(&json!({"type": "reply", "id": id, "sealed": sealed})),
                        1000,
                    );
                    ok(json!({"delivered": true}))
                }
                Some(d) => {
                    let release_at =
                        create_delayed(r, phone, &id, Some(w.machine.clone()), Some(sealed), d);
                    close_with(
                        &w.tx,
                        Some(&json!({"type": "delayed", "id": id, "releaseAt": release_at})),
                        1000,
                    );
                    r.push_all(phone, "delayed", &id, release_at);
                    ok(json!({"delivered": true, "releaseAt": release_at}))
                }
            }
        }
        AddDelayed => {
            enter!(&[Role::Phone]);
            let Some(id) = str_of("id").filter(|i| is_request_id(i)) else {
                return fail(400, "bad_id");
            };
            let Some(delay) = get("delay").and_then(valid_delay) else {
                return fail(400, "bad_delay");
            };
            let p = phone_mut(r, phone);
            live_delayed(p, now);
            if p.delayed.contains_key(&id) {
                return fail(409, "duplicate_id");
            }
            if p.delayed.len() >= MAX_DELAYED {
                return fail(429, "too_many_delayed");
            }
            let release_at = create_delayed(r, phone, &id, None, None, delay);
            r.push_all(phone, "delayed", &id, release_at);
            reply(
                StatusCode::CREATED,
                json!({"id": id, "releaseAt": release_at, "expires": release_at + DELAYED_KEEP_MS}),
            )
        }
        ListDelayed => {
            enter!(&both);
            let p = phone_mut(r, phone);
            live_delayed(p, now);
            let list: Vec<Value> = p
                .delayed
                .iter()
                .map(|(id, d)| delayed_view(id, d, now))
                .collect();
            ok(json!({"delayed": list}))
        }
        GetDelayed(id) => {
            let role = enter!(&both);
            if !is_request_id(&id) {
                return fail(400, "bad_id");
            }
            let p = phone_mut(r, phone);
            live_delayed(p, now);
            let Some(d) = p.delayed.get(&id) else {
                return fail(404, "gone");
            };
            let mut out = delayed_view(&id, d, now);
            let fetch = role == Role::Machine
                && d.machine.as_deref() == Some(signer)
                && d.cancelled.is_none()
                && now >= d.release_at
                && d.sealed.is_some();
            if fetch {
                out["sealed"] = json!(d.sealed);
                p.delayed.remove(&id);
            }
            ok(out)
        }
        CancelDelayed(id) => {
            let role = enter!(&both);
            if !is_request_id(&id) {
                return fail(400, "bad_id");
            }
            let p = phone_mut(r, phone);
            live_delayed(p, now);
            let Some(d) = p.delayed.get_mut(&id) else {
                return fail(404, "gone");
            };
            if d.cancelled.is_some() {
                return ok(json!({"cancelled": true}));
            }
            let by = if role == Role::Phone {
                "phone".to_owned()
            } else {
                signer.to_owned()
            };
            d.sealed = None;
            d.cancelled = Some(by.clone());
            let release_at = d.release_at;
            announce(p, &json!({"type": "cancelled", "id": id, "by": by}));
            r.push_all(phone, "cancelled", &id, release_at.max(now + 60_000));
            ok(json!({"cancelled": true}))
        }
        FinishDelayed(id) => {
            enter!(&[Role::Phone]);
            if !is_request_id(&id) {
                return fail(400, "bad_id");
            }
            let p = phone_mut(r, phone);
            live_delayed(p, now);
            let Some(d) = p.delayed.get(&id) else {
                return fail(404, "gone");
            };
            if d.machine.is_some() {
                return fail(400, "bad_id");
            }
            if let Some(by) = &d.cancelled {
                return fail_with(409, "cancelled", extra(&[("by", json!(by))]));
            }
            if now < d.release_at {
                return fail_with(
                    425,
                    "too_early",
                    extra(&[("releaseAt", json!(d.release_at))]),
                );
            }
            p.delayed.remove(&id);
            ok(json!({"finished": true}))
        }
        GetState => {
            enter!(&[Role::Phone]);
            let p = phone_mut(r, phone);
            match &p.state {
                Some((rev, blob)) => ok(json!({"rev": rev, "blob": blob})),
                None => ok(json!({"rev": 0, "blob": null})),
            }
        }
        PutState => {
            enter!(&[Role::Phone]);
            let Some(rev) = get("rev").and_then(Value::as_u64) else {
                return fail(400, "bad_rev");
            };
            let Some(blob) =
                str_of("blob").filter(|b| is_b64u(b, MAX_STATE_BYTES.div_ceil(3) * 4 + 4))
            else {
                return fail(400, "bad_blob");
            };
            match B64U.decode(&blob) {
                Ok(raw) if raw.len() > MAX_STATE_BYTES => return fail(413, "too_large"),
                Ok(_) => {}
                Err(_) => return fail(400, "bad_blob"),
            }
            let p = phone_mut(r, phone);
            let current = p.state.as_ref().map_or(0, |s| s.0);
            if rev != current {
                return fail_with(409, "conflict", extra(&[("rev", json!(current))]));
            }
            p.state = Some((current + 1, blob));
            ok(json!({"rev": current + 1}))
        }
        Licence => {
            enter!(&both);
            let p = phone_mut(r, phone);
            ok(
                json!({"licence": "unpaid", "source": null, "since": null, "movedTo": p.moved_to,
                      "revoked": null, "daysUsed": p.days_used, "ask": false,
                      "machines": p.machines.len(), "machineGate": null, "codes": []}),
            )
        }
        Checkout => {
            enter!(&both);
            fail(503, "payments_not_configured")
        }
        Claim => {
            enter!(&both);
            fail(404, "unknown_code")
        }
        Move => {
            enter!(&[Role::Phone]);
            let Some(to) = str_of("to").filter(|t| is_key_id(t) && t != phone) else {
                return fail(400, "bad_target");
            };
            if !str_of("proof").is_some_and(|p| p.len() == 86 && is_b64u(&p, 86)) {
                return fail(400, "bad_proof");
            }
            let days = phone_mut(r, phone).days_used;
            phone_mut(r, phone).moved_to = Some(to.clone());
            let target = phone_mut(r, &to);
            target.days_used = target.days_used.max(days);
            ok(json!({"movedTo": to, "licence": "unpaid", "daysUsed": target.days_used}))
        }
        ListPush => {
            enter!(&[Role::Phone]);
            let p = phone_mut(r, phone);
            let list: Vec<Value> = p
                .devices
                .iter()
                .map(|(device, d)| json!({"device": device, "platform": d.platform, "sandbox": d.sandbox, "updated": d.updated}))
                .collect();
            ok(json!({"devices": list}))
        }
        PutPush(device) => {
            enter!(&[Role::Phone]);
            if !is_request_id(&device) {
                return fail(400, "bad_device");
            }
            let token = str_of("token").unwrap_or_default();
            let d = match str_of("platform").as_deref() {
                Some("apns") => {
                    if !(64..=200).contains(&token.len())
                        || !token.bytes().all(|b| b.is_ascii_hexdigit())
                    {
                        return fail(400, "bad_token");
                    }
                    Device {
                        platform: "apns".into(),
                        token: token.to_lowercase(),
                        sandbox: get("sandbox") == Some(&Value::Bool(true)),
                        updated: now,
                    }
                }
                Some("fcm") => {
                    let okc =
                        |b: u8| b.is_ascii_alphanumeric() || matches!(b, b'_' | b':' | b'.' | b'-');
                    if token.is_empty() || token.len() > 1024 || !token.bytes().all(okc) {
                        return fail(400, "bad_token");
                    }
                    Device {
                        platform: "fcm".into(),
                        token,
                        sandbox: false,
                        updated: now,
                    }
                }
                _ => return fail(400, "bad_platform"),
            };
            let p = phone_mut(r, phone);
            p.devices.insert(device.clone(), d);
            while p.devices.len() > MAX_DEVICES {
                let oldest = p
                    .devices
                    .iter()
                    .filter(|(k, _)| **k != device)
                    .min_by_key(|(_, d)| d.updated)
                    .map(|(k, _)| k.clone())
                    .expect("more than one device");
                p.devices.remove(&oldest);
            }
            ok(json!({"devices": p.devices.len()}))
        }
        DeletePush(device) => {
            enter!(&[Role::Phone]);
            let p = phone_mut(r, phone);
            if p.devices.remove(&device).is_none() {
                return fail(404, "unknown_device");
            }
            ok(json!({"devices": p.devices.len()}))
        }
        TestPush(device) => {
            enter!(&[Role::Phone]);
            let p = phone_mut(r, phone);
            let Some(d) = p.devices.get(&device) else {
                return fail(404, "unknown_device");
            };
            let entry = json!({"phone": phone, "device": device, "platform": d.platform, "token": d.token,
                               "type": "test", "expires": now + 60_000});
            r.pushes.push(entry);
            ok(json!({"ok": true}))
        }
        PutStatus(machine) => {
            enter!(&[Role::Machine]);
            if signer != machine {
                return fail(403, "forbidden");
            }
            let Some(sealed) = str_of("sealed").filter(|s| is_b64u(s, MAX_STATUS)) else {
                return fail(400, "bad_sealed");
            };
            let p = phone_mut(r, phone);
            p.status.insert(machine.clone(), (sealed, now));
            for s in p.sockets.values() {
                send(&s.tx, &json!({"type": "status", "machine": machine}));
            }
            ok(json!({}))
        }
        ListStatus => {
            enter!(&[Role::Phone]);
            let p = phone_mut(r, phone);
            let list: Vec<Value> = p
                .machines
                .keys()
                .filter_map(|m| {
                    p.status
                        .get(m)
                        .map(|(s, u)| json!({"machine": m, "sealed": s, "updated": u}))
                })
                .collect();
            ok(json!({"status": list}))
        }
        PostMessage(machine) => {
            enter!(&[Role::Phone]);
            let Some(sealed) = str_of("sealed").filter(|s| is_b64u(s, MAX_MESSAGE)) else {
                return fail(400, "bad_sealed");
            };
            let p = phone_mut(r, phone);
            if !p.machines.contains_key(&machine) {
                return fail(404, "not_paired");
            }
            if let Some((_, tx)) = p.machine_sockets.get(&machine) {
                send(
                    tx,
                    &json!({"type": "message", "sealed": sealed, "created": now}),
                );
                return ok(json!({"delivered": true}));
            }
            let held = p.held.entry(machine).or_default();
            held.retain(|(_, c)| now.saturating_sub(*c) <= HELD_MS);
            held.push((sealed, now));
            if held.len() > MAX_HELD {
                let drop = held.len() - MAX_HELD;
                held.drain(..drop);
            }
            ok(json!({"delivered": false}))
        }
        Health | Lookup(_) | Wait | Socket | MachineSocket(_) => fail(404, "not_found"),
    }
}

// ------------------------------------------------------------ websockets ----

#[derive(Clone, Copy)]
enum SockKind {
    Wait,
    Phone,
    Machine,
}

fn upgrade_socket(
    shared: Shared,
    ws: WebSocketUpgrade,
    phone: String,
    signer: String,
    route: Route,
    ip: IpAddr,
) -> Response {
    let (tx, rx) = mpsc::unbounded_channel::<Out>();
    let kind;
    let conn;
    {
        let mut r = shared.lock().unwrap();
        let roles: &[Role] = match route {
            Route::Socket => &[Role::Phone],
            _ => &[Role::Machine],
        };
        if let Err(res) = enter(&mut r, &phone, &signer, roles, ip) {
            return res;
        }
        let now = r.now_ms();
        conn = r.conn();
        let p = phone_mut(&mut r, &phone);
        match route {
            Route::Socket => {
                kind = SockKind::Phone;
                p.sockets.insert(conn, PhoneSock { ip, tx: tx.clone() });
            }
            Route::Wait => {
                kind = SockKind::Wait;
                if p.waits.len() >= MAX_PENDING {
                    return fail(429, "too_many_pending");
                }
                p.waits.insert(
                    conn,
                    Wait {
                        machine: signer.clone(),
                        ip,
                        tx: tx.clone(),
                        pending: None,
                    },
                );
            }
            Route::MachineSocket(machine) => {
                kind = SockKind::Machine;
                if machine != signer {
                    return fail(403, "forbidden");
                }
                if let Some((_, old)) = p.machine_sockets.remove(&machine) {
                    close_with(&old, None, 1000);
                }
                for (sealed, created) in p.held.remove(&machine).unwrap_or_default() {
                    if now.saturating_sub(created) <= HELD_MS {
                        send(
                            &tx,
                            &json!({"type": "message", "sealed": sealed, "created": created}),
                        );
                    }
                }
                live_delayed(p, now);
                for (id, d) in &p.delayed {
                    if d.cancelled.is_none() && now < d.release_at {
                        send(
                            &tx,
                            &json!({"type": "delayed", "id": id, "machine": d.machine, "releaseAt": d.release_at}),
                        );
                    }
                }
                p.machine_sockets.insert(machine, (conn, tx.clone()));
            }
            _ => unreachable!("only socket routes upgrade"),
        }
    }
    ws.on_upgrade(move |socket| run_socket(socket, shared, phone, conn, kind, tx, rx))
}

async fn run_socket(
    socket: WebSocket,
    shared: Shared,
    phone: String,
    conn: u64,
    kind: SockKind,
    tx: Tx,
    mut rx: mpsc::UnboundedReceiver<Out>,
) {
    let (mut sink, mut stream) = socket.split();
    let writer = tokio::spawn(async move {
        while let Some(out) = rx.recv().await {
            match out {
                Out::Text(t) => {
                    if sink.send(Message::Text(t.into())).await.is_err() {
                        break;
                    }
                }
                Out::Close(code) => {
                    let _ = sink
                        .send(Message::Close(Some(CloseFrame {
                            code,
                            reason: "".into(),
                        })))
                        .await;
                    break;
                }
            }
        }
    });
    while let Some(Ok(msg)) = stream.next().await {
        let text = match msg {
            Message::Text(t) => t.to_string(),
            Message::Binary(b) => String::from_utf8_lossy(&b).into_owned(),
            Message::Close(_) => break,
            _ => continue,
        };
        if text == "ping" {
            let _ = tx.send(Out::Text("pong".into()));
            continue;
        }
        if text.len() > MAX_WS_MESSAGE {
            close_with(
                &tx,
                Some(&json!({"type": "error", "error": "too_large"})),
                1009,
            );
            continue;
        }
        match kind {
            SockKind::Phone => {}
            SockKind::Machine => {
                close_with(
                    &tx,
                    Some(&json!({"type": "error", "error": "bad_request"})),
                    1008,
                );
            }
            SockKind::Wait => on_wait_message(&shared, &phone, conn, &tx, &text),
        }
    }
    writer.abort();
    let mut r = shared.lock().unwrap();
    if let Some(p) = r.phones.get_mut(&phone) {
        match kind {
            SockKind::Wait => {
                p.waits.remove(&conn);
            }
            SockKind::Phone => {
                p.sockets.remove(&conn);
            }
            SockKind::Machine => {
                p.machine_sockets.retain(|_, (c, _)| *c != conn);
            }
        }
    }
}

fn on_wait_message(shared: &Shared, phone: &str, conn: u64, tx: &Tx, text: &str) {
    let fault =
        |e: &str, code: u16| close_with(tx, Some(&json!({"type": "error", "error": e})), code);
    let mut r = shared.lock().unwrap();
    let now = r.now_ms();
    let near_override = r.near;
    let Some(p) = r.phones.get_mut(phone) else {
        return fault("unpaired", 1008);
    };
    expire_waits(p, now);
    let Some(w) = p.waits.get(&conn) else { return };
    if w.pending.is_some() {
        return fault("one_request_per_socket", 1008);
    }
    let Ok(m) = serde_json::from_str::<Value>(text) else {
        return fault("bad_json", 1007);
    };
    let id = m
        .get("id")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_owned();
    let sealed = m
        .get("sealed")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_owned();
    if m.get("type").and_then(Value::as_str) != Some("request")
        || !is_request_id(&id)
        || !is_b64u(&sealed, MAX_SEALED)
    {
        return fault("bad_request", 1008);
    }
    let machine = w.machine.clone();
    let wait_ip = w.ip;
    if !p.machines.contains_key(&machine) {
        return fault("unpaired", 1008);
    }
    if p.waits
        .values()
        .any(|w| w.pending.as_ref().is_some_and(|pd| pd.id == id))
    {
        return fault("duplicate_id", 1008);
    }
    let ttl = m
        .get("ttl")
        .and_then(Value::as_f64)
        .filter(|t| *t >= 1.0)
        .map_or(MAX_TTL, |t| (t.floor() as u64).min(MAX_TTL));
    let expires = now + ttl * 1000;
    let w = p.waits.get_mut(&conn).expect("checked above");
    w.pending = Some(Pending {
        id: id.clone(),
        sealed: sealed.clone(),
        created: now,
        expires,
    });
    send(tx, &json!({"type": "queued", "id": id, "expires": expires}));
    for s in p.sockets.values() {
        let near = near_override.unwrap_or(s.ip == wait_ip);
        send(
            &s.tx,
            &json!({"type": "request", "id": id, "machine": machine, "sealed": sealed,
                    "created": now, "expires": expires, "near": near}),
        );
    }
    r.push_all(phone, "request", &id, expires);
    drop(r);
    // The machine keeps its own timer too; this closes the wait on time.
    let shared = shared.clone();
    let phone = phone.to_owned();
    tokio::spawn(async move {
        tokio::time::sleep(Duration::from_millis(ttl * 1000 + 50)).await;
        let mut r = shared.lock().unwrap();
        let now = r.now_ms().max(expires);
        if let Some(p) = r.phones.get_mut(&phone) {
            expire_waits(p, now);
        }
    });
}

// ------------------------------------------------------------ test routes ----

async fn test_route(shared: Shared, req: Request<Body>) -> Response {
    let path = req.uri().path().to_owned();
    let method = req.method().clone();
    let body = to_bytes(req.into_body(), MAX_STATE_BODY)
        .await
        .unwrap_or_default();
    let input: Value = serde_json::from_slice(&body).unwrap_or(Value::Null);
    let mut r = shared.lock().unwrap();
    match (method.as_str(), path.as_str()) {
        ("POST", "/test/near") => {
            r.near = input.get("near").and_then(Value::as_bool);
            ok(json!({"near": r.near}))
        }
        ("POST", "/test/fail") => {
            let mut extra = input.as_object().cloned().unwrap_or_default();
            let status = extra
                .remove("status")
                .and_then(|v| v.as_u64())
                .unwrap_or(503) as u16;
            let error = extra
                .remove("error")
                .and_then(|v| v.as_str().map(str::to_owned))
                .unwrap_or_else(|| "internal".into());
            let path = extra
                .remove("path")
                .and_then(|v| v.as_str().map(str::to_owned));
            let times = extra.remove("times").and_then(|v| v.as_u64()).unwrap_or(1) as u32;
            r.fails.push(Fail {
                status,
                error,
                path,
                times: times.max(1),
                extra,
            });
            ok(json!({"ok": true}))
        }
        ("POST", "/test/clock") => {
            r.offset_secs = input.get("offset").and_then(Value::as_i64).unwrap_or(0);
            ok(json!({"offset": r.offset_secs, "time": r.now_ms() / 1000}))
        }
        ("GET", "/test/replies") => ok(json!({"replies": r.replies})),
        ("GET", "/test/pushes") => ok(json!({"pushes": r.pushes})),
        ("POST", "/test/reset") => {
            for p in r.phones.values() {
                for w in p.waits.values() {
                    close_with(&w.tx, None, 1000);
                }
                for s in p.sockets.values() {
                    close_with(&s.tx, None, 1000);
                }
                for (_, tx) in p.machine_sockets.values() {
                    close_with(tx, None, 1000);
                }
            }
            *r = Relay::default();
            ok(json!({"ok": true}))
        }
        _ => fail(404, "not_found"),
    }
}
