//! The board's WebSocket: state and questions out, answers in.

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
use tokio::sync::broadcast::error::RecvError;

use crate::asks::Answered;
use crate::auth::check_bearer;
use crate::http::AppState;
use crate::protocol::{BoardMsg, ClientMsg, PROTOCOL_VERSION};

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

type Sink = SplitSink<WebSocket, Message>;

async fn send(sink: &mut Sink, msg: &BoardMsg) -> Result<(), axum::Error> {
    sink.send(Message::text(serde_json::to_string(msg).expect("BoardMsg serialises"))).await
}

/// The protocol version, then the full session list, then every question still waiting. Boards ignore
/// messages they do not know, so the greeting is safe to send to firmware that predates it.
async fn send_snapshot(s: &AppState, sink: &mut Sink) -> Result<(), axum::Error> {
    send(sink, &BoardMsg::Hello { version: PROTOCOL_VERSION }).await?;
    let sessions = s.registry.lock().unwrap().snapshot();
    send(sink, &BoardMsg::State { sessions }).await?;
    for ask in s.asks.pending() {
        send(sink, &BoardMsg::Question { ask }).await?;
    }
    Ok(())
}

const HISTORY_LIMIT: usize = 50;

/// The most a `history` frame may take on the wire. The board drops any frame over 64 KiB (`MAX_FRAME` in
/// the firmware's net.rs) without a word, so this leaves it room to spare; 50 full-size replies would not fit.
const HISTORY_BYTES: usize = 48 * 1024;

/// The `history` frame for a session: the newest entries that fit in `HISTORY_BYTES`, at most
/// `HISTORY_LIMIT`. Shared by the reply to `watch` and the resend after a lag.
fn history_msg(s: &AppState, host: &str, session: &str) -> BoardMsg {
    let empty = BoardMsg::History { host: host.into(), session: session.into(), entries: Vec::new() };
    let frame = serde_json::to_string(&empty).expect("BoardMsg serialises").len();
    let entries = s.feed.history_within(host, session, HISTORY_LIMIT, HISTORY_BYTES.saturating_sub(frame));
    BoardMsg::History { host: host.into(), session: session.into(), entries }
}

async fn send_history(s: &AppState, sink: &mut Sink, host: &str, session: &str) -> Result<(), axum::Error> {
    send(sink, &history_msg(s, host, session)).await
}

/// The session whose feed this socket follows, if any.
type Watching = Option<(String, String)>;

async fn handle(s: &AppState, sink: &mut Sink, watching: &mut Watching, text: &str) -> Result<(), axum::Error> {
    // A stale or replayed id is simply Unknown; nothing to tell the board.
    match serde_json::from_str::<ClientMsg>(text) {
        Ok(ClientMsg::Answer { id, answers }) => {
            let _ = s.asks.answer(&id, Answered::Answers(answers));
        }
        Ok(ClientMsg::Decline { id }) => {
            let _ = s.asks.answer(&id, Answered::Declined);
        }
        Ok(ClientMsg::Watch { host, session }) => {
            // Already subscribed to the broadcast, so an entry appended while the history is read
            // arrives twice at worst; the board dedupes by `n`.
            send_history(s, sink, &host, &session).await?;
            *watching = Some((host, session));
        }
        Ok(ClientMsg::Unwatch) => *watching = None,
        Err(_) => {}
    }
    Ok(())
}

async fn serve(s: AppState, socket: WebSocket) {
    let _connected = Connected::new(&s.board_connected);
    // Subscribe first so nothing between the snapshot and the loop is missed.
    let mut rx = s.tx.subscribe();
    let (mut sink, mut stream) = socket.split();
    if send_snapshot(&s, &mut sink).await.is_err() {
        return;
    }
    let mut watching: Watching = None;
    let mut ping = tokio::time::interval(s.ping_every);
    ping.tick().await;
    loop {
        tokio::select! {
            m = rx.recv() => match m {
                Ok(BoardMsg::Entry { host, session, entry }) => {
                    if watching.as_ref().is_some_and(|(h, w)| *h == host && *w == session)
                        && send(&mut sink, &BoardMsg::Entry { host, session, entry }).await.is_err()
                    {
                        break;
                    }
                }
                Ok(msg) => if send(&mut sink, &msg).await.is_err() { break },
                // Too slow to keep up: start over from a fresh snapshot, and the watched feed too.
                Err(RecvError::Lagged(_)) => {
                    if send_snapshot(&s, &mut sink).await.is_err() { break }
                    if let Some((h, w)) = &watching {
                        if send_history(&s, &mut sink, h, w).await.is_err() { break }
                    }
                }
                Err(RecvError::Closed) => break,
            },
            _ = ping.tick() => {
                if sink.send(Message::Ping(Bytes::new())).await.is_err() { break }
            }
            incoming = stream.next() => match incoming {
                Some(Ok(Message::Text(t))) => if handle(&s, &mut sink, &mut watching, t.as_str()).await.is_err() { break },
                Some(Ok(Message::Close(_))) | Some(Err(_)) | None => break,
                Some(Ok(_)) => {}
            }
        }
    }
}
