//! The bridge's `/mcp` proxying Home Assistant's MCP server, against a stub HA on 127.0.0.1:0.

use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use axum::Router;
use axum::body::Body;
use axum::extract::State;
use axum::http::{HeaderMap, Request, StatusCode, header};
use axum::response::{IntoResponse, Response};
use axum::routing::post;
use claude_board_bridge::mcp::ha::{EXCLUDED, HaMcp, UPSTREAM_TEXT_MAX};
use claude_board_bridge::mcp::{Mcp, Tool, ToolDef, ToolOutcome, mcp_router};
use futures_util::future::{BoxFuture, FutureExt};
use http_body_util::BodyExt;
use serde_json::{Value, json};
use tower::ServiceExt;

const HA_TOKEN: &str = "ha-secret-token-0123456789";

#[derive(Default)]
struct Stub {
    down: AtomicBool,
    /// Every request: (authorization header, accept header, JSON body).
    seen: Mutex<Vec<(Option<String>, Option<String>, Value)>>,
    calls: AtomicUsize,
}

type Shared = Arc<Stub>;

fn upstream_tools() -> Value {
    json!([
        {"name": "HassTurnOn", "description": "Turns on a device", "inputSchema": {"type": "object", "properties": {"name": {"type": "string"}}}},
        {"name": "HassCancelAllTimers", "description": "Cancels all timers", "inputSchema": {"type": "object"}},
        {"name": "GetLiveContext", "description": "The live state of exposed entities", "inputSchema": {"type": "object"}},
        {"name": "Big10", "description": "10 KB", "inputSchema": {"type": "object"}},
        {"name": "Big40", "description": "40 KB", "inputSchema": {"type": "object"}},
    ])
}

async fn ha(State(s): State<Shared>, headers: HeaderMap, body: String) -> Response {
    let get = |h: header::HeaderName| headers.get(h).and_then(|v| v.to_str().ok()).map(String::from);
    let msg: Value = serde_json::from_str(&body).unwrap_or(Value::Null);
    s.seen.lock().unwrap().push((get(header::AUTHORIZATION), get(header::ACCEPT), msg.clone()));
    if s.down.load(Ordering::SeqCst) {
        return StatusCode::SERVICE_UNAVAILABLE.into_response();
    }
    if get(header::AUTHORIZATION).as_deref() != Some(&format!("Bearer {HA_TOKEN}")) {
        return StatusCode::UNAUTHORIZED.into_response();
    }
    let Some(id) = msg.get("id").cloned() else {
        return StatusCode::ACCEPTED.into_response();
    };
    let ok = |result: Value| json!({"jsonrpc": "2.0", "id": id, "result": result});
    match msg["method"].as_str().unwrap_or("") {
        "initialize" => axum::Json(ok(json!({
            "protocolVersion": "2025-03-26",
            "capabilities": {"tools": {"listChanged": false}},
            "serverInfo": {"name": "home-assistant", "version": "1"},
        })))
        .into_response(),
        "tools/list" => axum::Json(ok(json!({"tools": upstream_tools()}))).into_response(),
        "tools/call" => {
            s.calls.fetch_add(1, Ordering::SeqCst);
            let name = msg["params"]["name"].as_str().unwrap_or("");
            let text = match name {
                "Big10" => "x".repeat(10 * 1024),
                "Big40" => "é".repeat(20 * 1024),
                _ => format!("{name} args={}", msg["params"]["arguments"]),
            };
            // Answered as server-sent events, which a streamable-HTTP server may do.
            let frame = ok(json!({"content": [{"type": "text", "text": text}], "isError": name == "HassTurnOn"}));
            ([(header::CONTENT_TYPE, "text/event-stream")], format!("event: message\ndata: {frame}\n\n")).into_response()
        }
        _ => axum::Json(json!({"jsonrpc": "2.0", "id": id, "error": {"code": -32601, "message": "nope"}})).into_response(),
    }
}

async fn stub() -> (String, Shared) {
    let s: Shared = Arc::default();
    let app = Router::new().route("/api/mcp", post(ha)).with_state(s.clone());
    let l = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = l.local_addr().unwrap();
    tokio::spawn(async move { axum::serve(l, app).await.unwrap() });
    (format!("http://{addr}"), s)
}

/// An address nothing listens on.
async fn closed() -> String {
    let l = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = l.local_addr().unwrap();
    drop(l);
    format!("http://{addr}")
}

struct Echo;
impl Tool for Echo {
    fn def(&self) -> ToolDef {
        ToolDef { name: "set_timer", description: "A local tool", input_schema: json!({"type": "object"}) }
    }
    fn call(&self, _args: Value) -> BoxFuture<'static, ToolOutcome> {
        async { ToolOutcome::Text("local".into()) }.boxed()
    }
}

fn app(ha_url: &str) -> Router {
    mcp_router(Arc::new(Mcp {
        tools: vec![Arc::new(Echo)],
        upstream: Some(Arc::new(HaMcp::new(ha_url.to_string(), HA_TOKEN.to_string()))),
        token: None,
        fail_delay: Duration::from_millis(1),
    }))
}

/// The raw response body and its JSON.
async fn rpc(app: &Router, body: Value) -> (String, Value) {
    let req = Request::builder()
        .method("POST")
        .uri("/mcp")
        .header("content-type", "application/json")
        .body(Body::from(body.to_string()))
        .unwrap();
    let r = app.clone().oneshot(req).await.unwrap();
    let bytes = r.into_body().collect().await.unwrap().to_bytes();
    let raw = String::from_utf8(bytes.to_vec()).unwrap();
    let v = serde_json::from_str(&raw).unwrap_or(Value::Null);
    assert!(!raw.contains(HA_TOKEN), "the HA token leaked: {raw}");
    (raw, v)
}

async fn list(app: &Router) -> Vec<Value> {
    rpc(app, json!({"jsonrpc": "2.0", "id": 1, "method": "tools/list"})).await.1["result"]["tools"]
        .as_array()
        .unwrap()
        .clone()
}

async fn call(app: &Router, name: &str, args: Value) -> Value {
    rpc(app, json!({"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {"name": name, "arguments": args}})).await.1
}

fn names(tools: &[Value]) -> Vec<&str> {
    tools.iter().map(|t| t["name"].as_str().unwrap()).collect()
}

#[tokio::test]
async fn list_merges_local_and_upstream_minus_the_excluded() {
    assert_eq!(EXCLUDED, ["HassCancelAllTimers"]);
    let (url, s) = stub().await;
    let app = app(&url);
    let tools = list(&app).await;
    assert_eq!(names(&tools), ["set_timer", "HassTurnOn", "GetLiveContext", "Big10", "Big40"]);
    let on = &tools[1];
    assert_eq!(on["description"], "Turns on a device");
    assert_eq!(on["inputSchema"], json!({"type": "object", "properties": {"name": {"type": "string"}}}));
    // The handshake and list, with the token and both accepted content types.
    let seen = s.seen.lock().unwrap();
    let methods: Vec<&str> = seen.iter().filter_map(|(_, _, b)| b["method"].as_str()).collect();
    assert_eq!(methods, ["initialize", "notifications/initialized", "tools/list"]);
    for (auth, accept, _) in seen.iter() {
        assert_eq!(auth.as_deref(), Some(format!("Bearer {HA_TOKEN}").as_str()));
        let accept = accept.as_deref().unwrap_or("");
        assert!(accept.contains("application/json") && accept.contains("text/event-stream"), "{accept}");
    }
    drop(seen);
    // Cached: a second list does not go back to HA.
    list(&app).await;
    assert_eq!(s.seen.lock().unwrap().len(), 3);
}

#[tokio::test]
async fn call_is_forwarded_with_its_arguments() {
    let (url, s) = stub().await;
    let app = app(&url);
    list(&app).await;
    let v = call(&app, "GetLiveContext", json!({"area": "kitchen", "n": 2})).await;
    assert_eq!(v["result"]["isError"], false);
    let text = v["result"]["content"][0]["text"].as_str().unwrap();
    assert_eq!(text, r#"GetLiveContext args={"area":"kitchen","n":2}"#);
    let seen = s.seen.lock().unwrap();
    let (auth, _, body) = seen.last().unwrap();
    assert_eq!(auth.as_deref(), Some(format!("Bearer {HA_TOKEN}").as_str()));
    assert_eq!(body["params"], json!({"name": "GetLiveContext", "arguments": {"area": "kitchen", "n": 2}}));
}

#[tokio::test]
async fn upstream_is_error_is_passed_back() {
    let (url, _) = stub().await;
    let app = app(&url);
    let v = call(&app, "HassTurnOn", json!({"name": "lamp"})).await;
    assert_eq!(v["result"]["isError"], true);
}

#[tokio::test]
async fn a_call_before_any_list_fetches_the_list_first() {
    let (url, s) = stub().await;
    let app = app(&url);
    let v = call(&app, "GetLiveContext", json!({})).await;
    assert_eq!(v["result"]["isError"], false);
    assert_eq!(s.calls.load(Ordering::SeqCst), 1);
}

#[tokio::test]
async fn excluded_and_unknown_names_are_refused_without_reaching_ha() {
    let (url, s) = stub().await;
    let app = app(&url);
    list(&app).await;
    for name in ["HassCancelAllTimers", "NoSuchTool"] {
        let v = call(&app, name, json!({})).await;
        assert_eq!(v["error"]["code"], -32602, "{name}: {v}");
    }
    assert_eq!(s.calls.load(Ordering::SeqCst), 0);
}

#[tokio::test]
async fn local_tools_still_answer_locally() {
    let (url, s) = stub().await;
    let app = app(&url);
    let v = call(&app, "set_timer", json!({})).await;
    assert_eq!(v["result"]["content"][0]["text"], "local");
    assert_eq!(s.calls.load(Ordering::SeqCst), 0);
}

#[tokio::test]
async fn ha_down_lists_local_tools_and_calls_answer_an_error_result() {
    let app = app(&closed().await);
    assert_eq!(names(&list(&app).await), ["set_timer"]);
    let v = call(&app, "GetLiveContext", json!({})).await;
    assert!(v.get("error").is_none(), "a transport error would make Hermes drop the server: {v}");
    assert_eq!(v["result"]["isError"], true);
    assert_eq!(v["result"]["content"][0]["text"], "Home Assistant is unavailable right now.");
}

#[tokio::test]
async fn ha_going_down_after_the_list_answers_an_error_result_and_recovers() {
    let (url, s) = stub().await;
    let app = app(&url);
    // Down from the start: only local tools, and the next list tries again.
    s.down.store(true, Ordering::SeqCst);
    assert_eq!(names(&list(&app).await), ["set_timer"]);
    s.down.store(false, Ordering::SeqCst);
    assert_eq!(list(&app).await.len(), 5);
    s.down.store(true, Ordering::SeqCst);
    let v = call(&app, "GetLiveContext", json!({})).await;
    assert_eq!(v["result"]["isError"], true);
    assert_eq!(v["result"]["content"][0]["text"], "Home Assistant is unavailable right now.");
    s.down.store(false, Ordering::SeqCst);
    assert_eq!(call(&app, "GetLiveContext", json!({})).await["result"]["isError"], false);
}

#[tokio::test]
async fn a_10_kb_result_arrives_whole() {
    let (url, _) = stub().await;
    let app = app(&url);
    let v = call(&app, "Big10", json!({})).await;
    assert_eq!(v["result"]["content"][0]["text"].as_str().unwrap(), "x".repeat(10 * 1024));
}

#[tokio::test]
async fn a_40_kb_result_is_capped_on_a_char_boundary() {
    assert_eq!(UPSTREAM_TEXT_MAX, 16 * 1024);
    let (url, _) = stub().await;
    let app = app(&url);
    let v = call(&app, "Big40", json!({})).await;
    let text = v["result"]["content"][0]["text"].as_str().unwrap();
    assert!(text.len() <= UPSTREAM_TEXT_MAX, "{}", text.len());
    assert!(text.len() > UPSTREAM_TEXT_MAX - 64, "{}", text.len());
    assert!(text.ends_with("[truncated]"));
    assert!(text.trim_end_matches("\n[truncated]").chars().all(|c| c == 'é'));
}
