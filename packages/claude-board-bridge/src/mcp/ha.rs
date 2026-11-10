//! Home Assistant's MCP server, proxied: the bridge's `/mcp` lists HA's Assist tools next to its own
//! and forwards their calls. The creature's Hermes has a terminal, so it must never hold the HA token:
//! with it, a prompt injection could call any HA service through the REST API, since HA has no
//! per-entity permissions and Assist exposure only limits the Assist and MCP APIs. The token stays
//! here, and HA's exposure settings still decide which entities the tools reach.
//!
//! Plain JSON-RPC POSTs to `<BRIDGE_HA_URL>/api/mcp`; HA issues no session id, but one is carried if
//! it does, and an answer framed as server-sent events is read too. Arguments, results and the token
//! are never logged.

use std::sync::Mutex;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;

use reqwest::header::{ACCEPT, CONTENT_TYPE};
use serde_json::{Value, json};

use super::cap_text_to;

/// HA tools never offered. `HassCancelAllTimers` acts on HA's timers, not the board's; hiding it keeps
/// "cancel my timers" on the bridge's `cancel_timer`.
pub const EXCLUDED: [&str; 1] = ["HassCancelAllTimers"];
/// The most text a proxied result may carry, in bytes. HA's `GetLiveContext` measured 7.6 KB and must
/// arrive whole, so this is well above `TOOL_TEXT_MAX`.
pub const UPSTREAM_TEXT_MAX: usize = 16 * 1024;
/// What a call answers when HA cannot be reached or refuses: a tool error, never a JSON-RPC error,
/// which would make Hermes drop the whole server.
pub const UNAVAILABLE: &str = "Home Assistant is unavailable right now.";

const TIMEOUT: Duration = Duration::from_secs(10);
const PROTOCOL_VERSION: &str = "2025-03-26";

/// What a forwarded call came to.
pub enum Forwarded {
    /// Not one of HA's tools (or excluded): the caller answers -32602.
    Unknown,
    /// HA's result: its text content joined and capped to `UPSTREAM_TEXT_MAX`, and its `isError`.
    Result { text: String, is_error: bool },
}

pub struct HaMcp {
    endpoint: String,
    token: String,
    client: reqwest::Client,
    /// HA's tools as listed (name, description, inputSchema), minus `EXCLUDED`; `None` until a list
    /// succeeds, so an unreachable HA is asked again next time.
    tools: Mutex<Option<Vec<Value>>>,
    session: Mutex<Option<String>>,
    next_id: AtomicU64,
}

impl HaMcp {
    /// `url` is HA's base URL (`BRIDGE_HA_URL`), `token` the contents of `BRIDGE_HA_TOKEN_FILE`.
    pub fn new(url: String, token: String) -> HaMcp {
        let client = reqwest::Client::builder().timeout(TIMEOUT).build().expect("reqwest client");
        HaMcp {
            endpoint: format!("{}/api/mcp", url.trim_end_matches('/')),
            token,
            client,
            tools: Mutex::new(None),
            session: Mutex::new(None),
            next_id: AtomicU64::new(1),
        }
    }

    /// HA's tools, from the cache or fetched now; empty (and not cached) if HA cannot be reached.
    pub async fn tools(&self) -> Vec<Value> {
        self.known().await.unwrap_or_default()
    }

    /// Forwards a call to one of HA's tools.
    pub async fn call(&self, name: &str, args: Value) -> Forwarded {
        if EXCLUDED.contains(&name) {
            return Forwarded::Unknown;
        }
        // With no list from HA there is no telling whether the name is one of its tools; say HA is
        // unavailable rather than that the tool does not exist.
        let Some(tools) = self.known().await else { return unavailable() };
        if !tools.iter().any(|t| t["name"] == name) {
            return Forwarded::Unknown;
        }
        let result = match self.request("tools/call", json!({"name": name, "arguments": args})).await {
            Ok(r) => r,
            Err(Failure::Refused) => {
                // HA answered with a JSON-RPC error (its tools may have changed): list afresh next time.
                *self.tools.lock().unwrap() = None;
                return unavailable();
            }
            Err(Failure::Unreachable) => return unavailable(),
        };
        let text: Vec<&str> = result["content"]
            .as_array()
            .map(|c| c.iter().filter(|i| i["type"] == "text").filter_map(|i| i["text"].as_str()).collect())
            .unwrap_or_default();
        Forwarded::Result {
            text: cap_text_to(&text.join("\n"), UPSTREAM_TEXT_MAX),
            is_error: result["isError"].as_bool().unwrap_or(false),
        }
    }

    async fn known(&self) -> Option<Vec<Value>> {
        if let Some(t) = self.tools.lock().unwrap().clone() {
            return Some(t);
        }
        let tools = self.fetch().await.ok()?;
        *self.tools.lock().unwrap() = Some(tools.clone());
        Some(tools)
    }

    async fn fetch(&self) -> Result<Vec<Value>, Failure> {
        self.request(
            "initialize",
            json!({
                "protocolVersion": PROTOCOL_VERSION,
                "capabilities": {},
                "clientInfo": {"name": "claude-board-bridge", "version": env!("CARGO_PKG_VERSION")},
            }),
        )
        .await?;
        self.post(json!({"jsonrpc": "2.0", "method": "notifications/initialized"})).await?;
        let list = self.request("tools/list", json!({})).await?;
        let tools = list["tools"].as_array().ok_or(Failure::Refused)?;
        Ok(tools
            .iter()
            .filter_map(|t| {
                let name = t["name"].as_str()?;
                if EXCLUDED.contains(&name) {
                    return None;
                }
                Some(json!({
                    "name": name,
                    "description": t["description"].as_str().unwrap_or(""),
                    "inputSchema": t.get("inputSchema").cloned().unwrap_or_else(|| json!({"type": "object"})),
                }))
            })
            .collect())
    }

    /// One JSON-RPC request; its `result`.
    async fn request(&self, method: &str, params: Value) -> Result<Value, Failure> {
        let id = self.next_id.fetch_add(1, Ordering::Relaxed);
        let body = self.post(json!({"jsonrpc": "2.0", "id": id, "method": method, "params": params})).await?;
        let msg = response_message(&body, id).ok_or(Failure::Unreachable)?;
        match msg.get("result") {
            Some(r) => Ok(r.clone()),
            None => Err(Failure::Refused),
        }
    }

    /// POSTs one message; the response body. Any non-success status is unreachable.
    async fn post(&self, msg: Value) -> Result<String, Failure> {
        let mut req = self
            .client
            .post(&self.endpoint)
            .bearer_auth(&self.token)
            .header(ACCEPT, "application/json, text/event-stream")
            .header(CONTENT_TYPE, "application/json")
            .body(msg.to_string());
        if let Some(s) = self.session.lock().unwrap().clone() {
            req = req.header("mcp-session-id", s);
        }
        let r = req.send().await.map_err(|_| Failure::Unreachable)?;
        if !r.status().is_success() {
            return Err(Failure::Unreachable);
        }
        if let Some(s) = r.headers().get("mcp-session-id").and_then(|v| v.to_str().ok()) {
            *self.session.lock().unwrap() = Some(s.to_string());
        }
        r.text().await.map_err(|_| Failure::Unreachable)
    }
}

enum Failure {
    /// No usable answer: a connection error, a timeout, a non-success status or an unreadable body.
    Unreachable,
    /// HA answered with a JSON-RPC error.
    Refused,
}

fn unavailable() -> Forwarded {
    Forwarded::Result { text: UNAVAILABLE.into(), is_error: true }
}

/// The JSON-RPC answer with `id` in a response body: a plain JSON object, or the `data:` lines of
/// server-sent events.
fn response_message(body: &str, id: u64) -> Option<Value> {
    let matches = |v: &Value| v.is_object() && v["id"] == id;
    if let Ok(v) = serde_json::from_str::<Value>(body.trim()) {
        return matches(&v).then_some(v);
    }
    // Events are separated by blank lines; one event's data lines are joined with newlines.
    body.replace("\r\n", "\n").split("\n\n").find_map(|event| {
        let data: Vec<&str> = event
            .lines()
            .filter_map(|l| l.strip_prefix("data:"))
            .map(|d| d.strip_prefix(' ').unwrap_or(d))
            .collect();
        let v: Value = serde_json::from_str(&data.join("\n")).ok()?;
        matches(&v).then_some(v)
    })
}
