//! A machine for tests: signed relay calls, the machine's stored state, pairing, sealed
//! requests and their replies. The `fake-machine` binary is a thin CLI over this.

use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use anyhow::{anyhow, bail, Context, Result};
use base64::engine::general_purpose::URL_SAFE_NO_PAD as B64U;
use base64::Engine;
use futures_util::{SinkExt, StreamExt};
use sealctl_core::relay_auth::machine_relay_headers;
use sealctl_core::{relay_headers, MachineKeys, PhoneKeys, RelayHeaders};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use tokio::net::TcpStream;
use tokio_tungstenite::tungstenite::client::IntoClientRequest;
use tokio_tungstenite::tungstenite::Message;
use tokio_tungstenite::{MaybeTlsStream, WebSocketStream};

/// The production relay.
pub const DEFAULT_RELAY: &str = "https://relay.sealctl.com";

/// A websocket to the relay.
pub type Socket = WebSocketStream<MaybeTlsStream<TcpStream>>;

/// Unix milliseconds now.
pub fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |d| d.as_millis() as u64)
}

/// Unpadded base64url.
pub fn b64u(bytes: &[u8]) -> String {
    B64U.encode(bytes)
}

/// Decodes unpadded base64url into exactly `N` bytes.
pub fn b64u_fixed<const N: usize>(text: &str) -> Result<[u8; N]> {
    let raw = B64U.decode(text).context("not base64url")?;
    raw.try_into().map_err(|_| anyhow!("expected {N} bytes"))
}

/// Installs the TLS crypto provider once (rustls needs one chosen at runtime).
pub fn init_tls() {
    let _ = rustls::crypto::aws_lc_rs::default_provider().install_default();
}

/// Who signs a relay call.
pub enum Signer<'a> {
    /// A machine, with its pairing key.
    Machine(&'a MachineKeys),
    /// The phone, with its identity key (used by tests that play the phone).
    Phone(&'a PhoneKeys),
}

impl Signer<'_> {
    fn headers(&self, method: &str, pq: &str, time: u64, body: &[u8]) -> RelayHeaders {
        match self {
            Signer::Machine(k) => machine_relay_headers(k, method, pq, time, body),
            Signer::Phone(k) => relay_headers(k, method.into(), pq.into(), time, body.to_vec()),
        }
    }
}

/// Signed HTTP and WebSocket calls to one relay.
#[derive(Clone)]
pub struct Relay {
    base: String,
    http: reqwest::Client,
    /// Seconds added to the local clock when signing (to test clock skew).
    pub skew: i64,
}

impl Relay {
    /// A client for `base`, e.g. `http://127.0.0.1:8787`.
    pub fn new(base: &str) -> Self {
        init_tls();
        Self {
            base: base.trim_end_matches('/').to_owned(),
            http: reqwest::Client::builder()
                .timeout(Duration::from_secs(20))
                .build()
                .expect("http client"),
            skew: 0,
        }
    }

    /// The base URL.
    pub fn base(&self) -> &str {
        &self.base
    }

    fn time(&self) -> u64 {
        (now_ms() as i64 / 1000 + self.skew).max(0) as u64
    }

    /// A signed call. Returns the status and the JSON body (`Null` when empty).
    pub async fn call(
        &self,
        signer: &Signer<'_>,
        method: &str,
        path: &str,
        body: Option<&Value>,
    ) -> Result<(u16, Value)> {
        let bytes = body.map(|b| b.to_string().into_bytes()).unwrap_or_default();
        let h = signer.headers(method, path, self.time(), &bytes);
        let method = reqwest::Method::from_bytes(method.as_bytes())?;
        let mut req = self
            .http
            .request(method, format!("{}{}", self.base, path))
            .header("Sealctl-Key", h.key)
            .header("Sealctl-Time", h.time)
            .header("Sealctl-Signature", h.signature);
        if body.is_some() {
            req = req.header("content-type", "application/json").body(bytes);
        }
        let res = req
            .send()
            .await
            .with_context(|| format!("calling {path}"))?;
        let status = res.status().as_u16();
        let text = res.text().await.unwrap_or_default();
        let json = if text.is_empty() {
            Value::Null
        } else {
            serde_json::from_str(&text).unwrap_or(Value::String(text))
        };
        Ok((status, json))
    }

    /// An unsigned call (health, `/test/` routes).
    pub async fn plain(
        &self,
        method: &str,
        path: &str,
        body: Option<&Value>,
    ) -> Result<(u16, Value)> {
        let method = reqwest::Method::from_bytes(method.as_bytes())?;
        let mut req = self.http.request(method, format!("{}{}", self.base, path));
        if let Some(b) = body {
            req = req.json(b);
        }
        let res = req.send().await?;
        let status = res.status().as_u16();
        Ok((status, res.json().await.unwrap_or(Value::Null)))
    }

    /// Opens a signed WebSocket (`/wait`, `/socket`, a machine socket).
    pub async fn socket(&self, signer: &Signer<'_>, path: &str) -> Result<Socket> {
        let h = signer.headers("GET", path, self.time(), b"");
        let url = format!("{}{}", self.base.replacen("http", "ws", 1), path);
        let mut req = url.into_client_request()?;
        let hs = req.headers_mut();
        hs.insert("Sealctl-Key", h.key.parse()?);
        hs.insert("Sealctl-Time", h.time.parse()?);
        hs.insert("Sealctl-Signature", h.signature.parse()?);
        match tokio_tungstenite::connect_async(req).await {
            Ok((ws, _)) => Ok(ws),
            Err(tokio_tungstenite::tungstenite::Error::Http(res)) => {
                let body = res
                    .body()
                    .as_ref()
                    .map(|b| String::from_utf8_lossy(b).into_owned())
                    .unwrap_or_default();
                bail!(
                    "relay refused the socket: {} {}",
                    res.status().as_u16(),
                    body
                )
            }
            Err(e) => Err(e.into()),
        }
    }
}

/// Sends one text message.
pub async fn send_text(ws: &mut Socket, text: &str) -> Result<()> {
    ws.send(Message::Text(text.to_owned().into())).await?;
    Ok(())
}

/// The next JSON message, skipping `pong`; `None` when the socket closed. Sends `ping`
/// every 30 seconds while waiting, as the relay asks.
pub async fn next_json(ws: &mut Socket, deadline: tokio::time::Instant) -> Result<Option<Value>> {
    loop {
        let ping = tokio::time::Instant::now() + Duration::from_secs(30);
        let until = ping.min(deadline);
        match tokio::time::timeout_at(until, ws.next()).await {
            Err(_) if until == deadline => bail!("timed out"),
            Err(_) => {
                ws.send(Message::Text("ping".into())).await?;
            }
            Ok(None) => return Ok(None),
            Ok(Some(Err(e))) => {
                return match e {
                    tokio_tungstenite::tungstenite::Error::ConnectionClosed
                    | tokio_tungstenite::tungstenite::Error::AlreadyClosed => Ok(None),
                    e => Err(e.into()),
                }
            }
            Ok(Some(Ok(Message::Text(t)))) => {
                if t.as_str() == "pong" {
                    continue;
                }
                return Ok(Some(
                    serde_json::from_str(t.as_str()).unwrap_or(Value::String(t.to_string())),
                ));
            }
            Ok(Some(Ok(Message::Close(_)))) => return Ok(None),
            Ok(Some(Ok(_))) => continue,
        }
    }
}

// ----------------------------------------------------------- machine state ----

/// What the fake machine knows about an object it holds.
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
pub struct Object {
    /// Purpose (`secrets`, `secret`, `volume`, `backup`).
    pub purpose: String,
    /// Object id.
    pub id: String,
    /// Words fingerprint it was sealed with.
    pub words: Option<String>,
    /// Key check.
    pub check: Option<String>,
}

/// The fake machine's stored state (`<home>/machine.json`).
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct MachineState {
    /// Pairing seed and box key, 64 bytes as base64url.
    pub keys: String,
    /// `user@host`.
    pub name: String,
    /// OS.
    pub os: String,
    /// Model.
    pub model: Option<String>,
    /// Hardware hint.
    pub hint: Option<String>,
    /// Relay origin used at pairing.
    pub relay: String,
    /// Paired phone identity `P`.
    pub phone: Option<String>,
    /// Paired phone box key `X`.
    pub phone_box: Option<String>,
    /// The phone key before the last move proof.
    pub old_phone: Option<String>,
    /// Objects and their checks.
    #[serde(default)]
    pub objects: Vec<Object>,
    /// Highest machine message `seq` seen.
    #[serde(default)]
    pub message_seq: u64,
    /// Last status `seq` sent.
    #[serde(default)]
    pub status_seq: u64,
    /// Hash of the last `unseal` plan sent.
    #[serde(default)]
    pub last_plan: Option<String>,
}

impl MachineState {
    /// The state file in `home`.
    pub fn path(home: &Path) -> PathBuf {
        home.join("machine.json")
    }

    /// Loads the state from `home`.
    pub fn load(home: &Path) -> Result<Self> {
        let text = std::fs::read_to_string(Self::path(home))
            .with_context(|| format!("no fake machine in {} (run `pair` first)", home.display()))?;
        Ok(serde_json::from_str(&text)?)
    }

    /// Saves the state to `home` (file mode 0600).
    pub fn save(&self, home: &Path) -> Result<()> {
        std::fs::create_dir_all(home)?;
        let path = Self::path(home);
        let tmp = path.with_extension("tmp");
        std::fs::write(&tmp, serde_json::to_string_pretty(self)?)?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&tmp, std::fs::Permissions::from_mode(0o600))?;
        }
        std::fs::rename(tmp, path)?;
        Ok(())
    }

    /// The machine keys.
    pub fn machine_keys(&self) -> Result<MachineKeys> {
        let raw = B64U.decode(&self.keys)?;
        Ok(MachineKeys::from_bytes(&raw)?)
    }

    /// The paired phone, as `(P, X)` bytes.
    pub fn phone_public(&self) -> Result<sealctl_core::PhonePublic> {
        let (Some(p), Some(x)) = (&self.phone, &self.phone_box) else {
            bail!("not paired");
        };
        Ok(sealctl_core::PhonePublic::from_b64u(p, x)?)
    }

    /// The stored facts of an object.
    pub fn object(&self, purpose: &str, id: &str) -> Option<&Object> {
        self.objects
            .iter()
            .find(|o| o.purpose == purpose && o.id == id)
    }

    /// Records an object's words and check.
    pub fn remember(&mut self, obj: Object) {
        match self
            .objects
            .iter_mut()
            .find(|o| o.purpose == obj.purpose && o.id == obj.id)
        {
            Some(o) => *o = obj,
            None => self.objects.push(obj),
        }
    }
}

/// 16 random bytes.
pub fn random16() -> Result<[u8; 16]> {
    let mut b = [0u8; 16];
    getrandom::fill(&mut b).map_err(|e| anyhow!("random: {e}"))?;
    Ok(b)
}
