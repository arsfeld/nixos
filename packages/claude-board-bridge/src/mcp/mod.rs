//! A minimal MCP server (JSON-RPC 2.0 over HTTP POST, tools only) for the creature's Hermes.
//! It listens on loopback on its own port. Logs carry tool names and timings, never arguments
//! or results.

use std::sync::Arc;
use std::time::{Duration, Instant};

use axum::Router;
use axum::extract::State;
use axum::http::{HeaderMap, StatusCode};
use axum::response::{IntoResponse, Response};
use axum::routing::post;
use futures_util::future::BoxFuture;
use serde_json::{Value, json};

use crate::auth::check_bearer;

/// The longest tool result text, in bytes.
pub const TOOL_TEXT_MAX: usize = 3000;
const TRUNCATED: &str = "\n[truncated]";
const VERSIONS: [&str; 3] = ["2025-06-18", "2025-03-26", "2024-11-05"];

/// `s` unchanged if it fits `TOOL_TEXT_MAX`, else cut on a char boundary with a marker appended.
pub fn cap_text(s: &str) -> String {
    if s.len() <= TOOL_TEXT_MAX {
        return s.to_string();
    }
    let mut end = TOOL_TEXT_MAX - TRUNCATED.len();
    while !s.is_char_boundary(end) {
        end -= 1;
    }
    format!("{}{TRUNCATED}", &s[..end])
}

pub struct ToolDef {
    pub name: &'static str,
    pub description: &'static str,
    pub input_schema: Value,
}

/// What a tool returns; both are capped to `TOOL_TEXT_MAX`, and `Error` becomes `isError: true`.
pub enum ToolOutcome {
    Text(String),
    Error(String),
}

pub trait Tool: Send + Sync {
    fn def(&self) -> ToolDef;
    fn call(&self, args: Value) -> BoxFuture<'static, ToolOutcome>;
}

pub struct Mcp {
    pub tools: Vec<Arc<dyn Tool>>,
    /// Required as a bearer token when set.
    pub token: Option<String>,
    pub fail_delay: Duration,
}

pub fn mcp_router(mcp: Arc<Mcp>) -> Router {
    Router::new().route("/mcp", post(handle)).with_state(mcp)
}

fn reply(id: Value, result: Value) -> Response {
    axum::Json(json!({"jsonrpc":"2.0","id":id,"result":result})).into_response()
}

fn fail(id: Value, code: i64, message: &str) -> Response {
    axum::Json(json!({"jsonrpc":"2.0","id":id,"error":{"code":code,"message":message}})).into_response()
}

async fn handle(State(mcp): State<Arc<Mcp>>, headers: HeaderMap, body: String) -> Response {
    if let Some(token) = &mcp.token {
        if let Err(code) = check_bearer(&headers, token, mcp.fail_delay).await {
            return code.into_response();
        }
    }
    let msg: Value = match serde_json::from_str(&body) {
        Ok(v @ Value::Object(_)) => v,
        _ => return fail(Value::Null, -32600, "expected one JSON-RPC object"),
    };
    let Some(id) = msg.get("id").cloned() else {
        return StatusCode::ACCEPTED.into_response();
    };
    let Some(method) = msg.get("method").and_then(Value::as_str) else {
        return fail(id, -32600, "missing method");
    };
    let params = msg.get("params").cloned().unwrap_or(Value::Null);
    match method {
        "initialize" => {
            let want = params.get("protocolVersion").and_then(Value::as_str).unwrap_or("");
            let version = if VERSIONS.contains(&want) { want } else { "2025-03-26" };
            reply(
                id,
                json!({
                    "protocolVersion": version,
                    "capabilities": {"tools": {}},
                    "serverInfo": {"name": "claude-board", "version": env!("CARGO_PKG_VERSION")},
                }),
            )
        }
        "ping" => reply(id, json!({})),
        "tools/list" => {
            let tools: Vec<Value> = mcp
                .tools
                .iter()
                .map(|t| {
                    let d = t.def();
                    json!({"name": d.name, "description": d.description, "inputSchema": d.input_schema})
                })
                .collect();
            reply(id, json!({"tools": tools}))
        }
        "tools/call" => {
            let name = params.get("name").and_then(Value::as_str).unwrap_or("");
            let Some(tool) = mcp.tools.iter().find(|t| t.def().name == name) else {
                return fail(id, -32602, "unknown tool");
            };
            let args = params.get("arguments").cloned().unwrap_or_else(|| json!({}));
            let started = Instant::now();
            let outcome = tool.call(args).await;
            let (text, is_error) = match outcome {
                ToolOutcome::Text(t) => (cap_text(&t), false),
                ToolOutcome::Error(t) => (cap_text(&t), true),
            };
            eprintln!("mcp: tool={name} ms={} error={is_error}", started.elapsed().as_millis());
            reply(id, json!({"content": [{"type": "text", "text": text}], "isError": is_error}))
        }
        _ => fail(id, -32601, "method not found"),
    }
}
