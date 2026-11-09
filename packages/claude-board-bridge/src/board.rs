//! The board's WebSocket: state and questions out, answers in.

use std::collections::BTreeMap;
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};

use axum::Router;
use axum::body::Bytes;
use axum::extract::State;
use axum::extract::ws::{Message, WebSocket, WebSocketUpgrade};
use axum::http::{HeaderMap, StatusCode};
use axum::response::Response;
use axum::routing::get;
use futures_util::stream::SplitSink;
use futures_util::{SinkExt, StreamExt};
use serde::Deserialize;
use tokio::sync::broadcast::error::RecvError;

use crate::asks::{Answered, AskId};
use crate::auth::check_bearer;
use crate::http::AppState;
use crate::protocol::BoardMsg;

pub fn board_router(state: AppState) -> Router {
    Router::new().route("/v1/board", get(board)).with_state(state)
}

async fn board(State(s): State<AppState>, headers: HeaderMap, ws: WebSocketUpgrade) -> Result<Response, StatusCode> {
    check_bearer(&headers, &s.tokens.device, s.fail_delay).await?;
    Ok(ws.on_upgrade(move |socket| serve(s, socket)))
}

/// Counts a live board socket for as long as it exists.
struct Connected(Arc<AtomicUsize>);

impl Connected {
    fn new(n: &Arc<AtomicUsize>) -> Connected {
        n.fetch_add(1, Ordering::SeqCst);
        Connected(n.clone())
    }
}

impl Drop for Connected {
    fn drop(&mut self) {
        self.0.fetch_sub(1, Ordering::SeqCst);
    }
}

/// What a board may send. Anything else is ignored.
#[derive(Deserialize)]
#[serde(tag = "t", rename_all = "snake_case")]
enum ClientMsg {
    Answer { id: AskId, answers: BTreeMap<String, String> },
    Decline { id: AskId },
}

type Sink = SplitSink<WebSocket, Message>;

async fn send(sink: &mut Sink, msg: &BoardMsg) -> Result<(), axum::Error> {
    sink.send(Message::text(serde_json::to_string(msg).expect("BoardMsg serialises"))).await
}

/// The full session list, then every question still waiting.
async fn send_snapshot(s: &AppState, sink: &mut Sink) -> Result<(), axum::Error> {
    let sessions = s.registry.lock().unwrap().snapshot();
    send(sink, &BoardMsg::State { sessions }).await?;
    for ask in s.asks.pending() {
        send(sink, &BoardMsg::Question { ask }).await?;
    }
    Ok(())
}

fn handle(s: &AppState, text: &str) {
    // A stale or replayed id is simply Unknown; nothing to tell the board.
    match serde_json::from_str::<ClientMsg>(text) {
        Ok(ClientMsg::Answer { id, answers }) => {
            let _ = s.asks.answer(&id, Answered::Answers(answers));
        }
        Ok(ClientMsg::Decline { id }) => {
            let _ = s.asks.answer(&id, Answered::Declined);
        }
        Err(_) => {}
    }
}

async fn serve(s: AppState, socket: WebSocket) {
    let _connected = Connected::new(&s.board_connected);
    // Subscribe first so nothing between the snapshot and the loop is missed.
    let mut rx = s.tx.subscribe();
    let (mut sink, mut stream) = socket.split();
    if send_snapshot(&s, &mut sink).await.is_err() {
        return;
    }
    let mut ping = tokio::time::interval(s.ping_every);
    ping.tick().await;
    loop {
        tokio::select! {
            m = rx.recv() => match m {
                Ok(msg) => if send(&mut sink, &msg).await.is_err() { break },
                // Too slow to keep up: start over from a fresh snapshot.
                Err(RecvError::Lagged(_)) => if send_snapshot(&s, &mut sink).await.is_err() { break },
                Err(RecvError::Closed) => break,
            },
            _ = ping.tick() => {
                if sink.send(Message::Ping(Bytes::new())).await.is_err() { break }
            }
            incoming = stream.next() => match incoming {
                Some(Ok(Message::Text(t))) => handle(&s, t.as_str()),
                Some(Ok(Message::Close(_))) | Some(Err(_)) | None => break,
                Some(Ok(_)) => {}
            }
        }
    }
}
