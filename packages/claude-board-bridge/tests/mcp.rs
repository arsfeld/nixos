use std::sync::Arc;
use std::time::Duration;

use axum::Router;
use axum::body::Body;
use axum::http::{Request, StatusCode};
use claude_board_bridge::mcp::{Mcp, Tool, ToolDef, ToolOutcome, mcp_router};
use futures_util::future::{BoxFuture, FutureExt};
use http_body_util::BodyExt;
use serde_json::{Value, json};
use tower::ServiceExt;

struct Echo;
impl Tool for Echo {
    fn def(&self) -> ToolDef {
        ToolDef {
            name: "echo",
            description: "Echo the text back",
            input_schema: json!({"type":"object","properties":{"text":{"type":"string"}}}),
        }
    }
    fn call(&self, args: Value) -> BoxFuture<'static, ToolOutcome> {
        let t = args["text"].as_str().unwrap_or("").to_string();
        async move { ToolOutcome::Text(t) }.boxed()
    }
}

struct Big;
impl Tool for Big {
    fn def(&self) -> ToolDef {
        ToolDef { name: "big", description: "Big result", input_schema: json!({"type":"object"}) }
    }
    fn call(&self, _args: Value) -> BoxFuture<'static, ToolOutcome> {
        async { ToolOutcome::Text("é".repeat(5000)) }.boxed()
    }
}

fn app(token: Option<&str>) -> Router {
    mcp_router(Arc::new(Mcp {
        tools: vec![Arc::new(Echo), Arc::new(Big)],
        token: token.map(String::from),
        fail_delay: Duration::from_millis(1),
    }))
}

fn post(token: Option<&str>, body: &str) -> Request<Body> {
    let mut b = Request::builder().method("POST").uri("/mcp").header("content-type", "application/json");
    if let Some(t) = token {
        b = b.header("authorization", format!("Bearer {t}"));
    }
    b.body(Body::from(body.to_string())).unwrap()
}

async fn rpc(app: &Router, body: Value) -> (StatusCode, Value) {
    let r = app.clone().oneshot(post(None, &body.to_string())).await.unwrap();
    let s = r.status();
    let bytes = r.into_body().collect().await.unwrap().to_bytes();
    (s, serde_json::from_slice(&bytes).unwrap_or(Value::Null))
}

#[tokio::test]
async fn initialize_echoes_a_known_version() {
    let (s, v) = rpc(&app(None), json!({"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05"}})).await;
    assert_eq!(s, StatusCode::OK);
    assert_eq!(v["id"], 1);
    assert_eq!(v["result"]["protocolVersion"], "2024-11-05");
    assert_eq!(v["result"]["capabilities"], json!({"tools":{}}));
    assert_eq!(v["result"]["serverInfo"]["name"], "claude-board");
    assert_eq!(v["result"]["serverInfo"]["version"], env!("CARGO_PKG_VERSION"));
}

#[tokio::test]
async fn initialize_falls_back_for_an_unknown_version() {
    let (_, v) = rpc(&app(None), json!({"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"1999-01-01"}})).await;
    assert_eq!(v["result"]["protocolVersion"], "2025-03-26");
}

#[tokio::test]
async fn tools_list_names_every_tool() {
    let (_, v) = rpc(&app(None), json!({"jsonrpc":"2.0","id":2,"method":"tools/list"})).await;
    let tools = v["result"]["tools"].as_array().unwrap();
    let names: Vec<&str> = tools.iter().map(|t| t["name"].as_str().unwrap()).collect();
    assert_eq!(names, ["echo", "big"]);
    assert_eq!(tools[0]["description"], "Echo the text back");
    assert_eq!(tools[0]["inputSchema"]["type"], "object");
}

#[tokio::test]
async fn call_returns_text_content() {
    let (_, v) = rpc(
        &app(None),
        json!({"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"echo","arguments":{"text":"hi"}}}),
    )
    .await;
    assert_eq!(v["result"]["content"], json!([{"type":"text","text":"hi"}]));
    assert_eq!(v["result"]["isError"], false);
}

#[tokio::test]
async fn call_of_unknown_tool_is_invalid_params() {
    let (_, v) = rpc(&app(None), json!({"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"nope"}})).await;
    assert_eq!(v["error"]["code"], -32602);
}

#[tokio::test]
async fn unknown_method_is_method_not_found() {
    let (_, v) = rpc(&app(None), json!({"jsonrpc":"2.0","id":4,"method":"resources/list"})).await;
    assert_eq!(v["error"]["code"], -32601);
}

#[tokio::test]
async fn ping_returns_empty_object() {
    let (_, v) = rpc(&app(None), json!({"jsonrpc":"2.0","id":5,"method":"ping"})).await;
    assert_eq!(v["result"], json!({}));
}

#[tokio::test]
async fn batch_is_invalid_request() {
    let (_, v) = rpc(&app(None), json!([{"jsonrpc":"2.0","id":1,"method":"ping"}])).await;
    assert_eq!(v["error"]["code"], -32600);
}

#[tokio::test]
async fn notification_is_202_empty() {
    let r = app(None)
        .oneshot(post(None, r#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#))
        .await
        .unwrap();
    assert_eq!(r.status(), StatusCode::ACCEPTED);
    assert!(r.into_body().collect().await.unwrap().to_bytes().is_empty());
}

#[tokio::test]
async fn missing_token_is_401() {
    let r = app(Some("s3cret")).oneshot(post(None, r#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#)).await.unwrap();
    assert_eq!(r.status(), StatusCode::UNAUTHORIZED);
}

#[tokio::test]
async fn wrong_token_is_401() {
    let r = app(Some("s3cret")).oneshot(post(Some("nope"), r#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#)).await.unwrap();
    assert_eq!(r.status(), StatusCode::UNAUTHORIZED);
}

#[tokio::test]
async fn right_token_is_accepted() {
    let r = app(Some("s3cret")).oneshot(post(Some("s3cret"), r#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#)).await.unwrap();
    assert_eq!(r.status(), StatusCode::OK);
}

#[tokio::test]
async fn no_token_configured_needs_no_header() {
    let r = app(None).oneshot(post(None, r#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#)).await.unwrap();
    assert_eq!(r.status(), StatusCode::OK);
}

#[tokio::test]
async fn big_result_is_capped_on_a_char_boundary() {
    let (_, v) = rpc(&app(None), json!({"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"big"}})).await;
    let text = v["result"]["content"][0]["text"].as_str().unwrap();
    assert!(text.len() <= 3000);
    assert!(text.ends_with("[truncated]"));
}
