//! The board's WebSocket: state and questions out, answers in.

use std::sync::{Arc, Mutex};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::Duration;

use tokio::task::JoinHandle;
use tokio::time::Instant;

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
use tokio::sync::mpsc::{self, Receiver, UnboundedReceiver, UnboundedSender};
use tokio::sync::{Notify, broadcast};

use crate::voice::{Conn, Out};

use crate::asks::Answered;
use crate::auth::check_bearer;
use crate::http::{AppState, UplinkStats};
use crate::protocol::{BoardMsg, ClientMsg, Mood, PROTOCOL_VERSION};

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

/// The session whose feed this socket follows, if any. Set by the reader, read by the writer.
type Watching = Arc<Mutex<Option<(String, String)>>>;

/// Audio bytes allowed in the queue between the reader and the voice task.
const MAX_QUEUED_AUDIO: usize = 256 * 1024;
/// Control messages allowed in that queue.
const MAX_QUEUED_CONTROL: usize = 64;

/// What the reader has queued for the voice task, which decrements as it processes.
#[derive(Default)]
struct Queued {
    audio: AtomicUsize,
    control: AtomicUsize,
}

/// What the reader hands to the voice task. The channel is unbounded so the reader never waits on
/// the voice side; `Queued` bounds it instead, and the reader drops what would exceed it.
enum Voice {
    Client(ClientMsg),
    Audio(Vec<u8>),
}

/// Handles one incoming text frame. Never waits on the writer: a `watch` only records the session and
/// wakes the writer, which sends the history.
fn handle(s: &AppState, watching: &Watching, history: &Notify, voice: &mut Uplink, text: &str) {
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
            *watching.lock().unwrap() = Some((host, session));
            history.notify_one();
        }
        Ok(ClientMsg::Unwatch) => *watching.lock().unwrap() = None,
        Ok(msg @ (ClientMsg::VoiceStart { .. } | ClientMsg::VoiceEnd { .. } | ClientMsg::Cancel { .. })) => {
            voice.control(msg);
        }
        Err(_) => {}
    }
}

/// Owns the voice pipeline for one socket. Ends when the reader drops its sender.
async fn voice_task(mut conn: Conn, mut rx: UnboundedReceiver<Voice>, queued: Arc<Queued>) {
    while let Some(m) = rx.recv().await {
        match m {
            Voice::Client(msg) => {
                queued.control.fetch_sub(1, Ordering::SeqCst);
                conn.on_client(&msg).await
            }
            Voice::Audio(frame) => {
                queued.audio.fetch_sub(frame.len(), Ordering::SeqCst);
                conn.on_audio(&frame)
            }
        }
    }
}

/// Aborts its task when dropped, so a task cannot outlive `serve` even if its future is dropped.
struct AbortOnDrop(JoinHandle<()>);

impl Drop for AbortOnDrop {
    fn drop(&mut self) {
        self.0.abort();
    }
}

/// The reader's side of the uplink bounds: queues for the voice task or drops, and counts the drops.
struct Uplink {
    tx: UnboundedSender<Voice>,
    queued: Arc<Queued>,
    stats: Arc<UplinkStats>,
    dropped_since_log: usize,
    last_log: Instant,
}

impl Uplink {
    fn drop_one(&mut self) {
        self.stats.dropped_frames.fetch_add(1, Ordering::SeqCst);
        self.dropped_since_log += 1;
        if self.last_log.elapsed() >= Duration::from_secs(1) {
            eprintln!("voice: uplink dropped {} frames", self.dropped_since_log);
            self.dropped_since_log = 0;
            self.last_log = Instant::now();
        }
    }

    fn control(&mut self, msg: ClientMsg) {
        if self.queued.control.load(Ordering::SeqCst) >= MAX_QUEUED_CONTROL {
            return self.drop_one();
        }
        self.queued.control.fetch_add(1, Ordering::SeqCst);
        let _ = self.tx.send(Voice::Client(msg));
    }

    fn audio(&mut self, frame: Vec<u8>) {
        let now = self.queued.audio.load(Ordering::SeqCst) + frame.len();
        if now > MAX_QUEUED_AUDIO {
            return self.drop_one();
        }
        self.queued.audio.fetch_add(frame.len(), Ordering::SeqCst);
        self.stats.peak_queued_bytes.fetch_max(now, Ordering::SeqCst);
        let _ = self.tx.send(Voice::Audio(frame));
    }
}

/// The socket's only writer: the greeting, then broadcasts, voice output, histories and pings until a
/// send fails. Nothing here is awaited by the reader, so a board that stops draining stalls this task
/// and nothing else.
async fn writer(
    s: AppState,
    mut sink: Sink,
    mut rx: broadcast::Receiver<BoardMsg>,
    mut out: Receiver<Out>,
    watching: Watching,
    history: Arc<Notify>,
) {
    if send_snapshot(&s, &mut sink).await.is_err() {
        return;
    }
    let mood = if s.voice.is_some() { Mood::Idle } else { Mood::Offline };
    if send(&mut sink, &BoardMsg::Creature { mood }).await.is_err() {
        return;
    }
    let mut ping = tokio::time::interval(s.ping_every);
    ping.tick().await;
    loop {
        let sent = tokio::select! {
            m = rx.recv() => match m {
                Ok(BoardMsg::Entry { host, session, entry }) => {
                    let watched = watching.lock().unwrap().as_ref().is_some_and(|(h, w)| *h == host && *w == session);
                    if watched { send(&mut sink, &BoardMsg::Entry { host, session, entry }).await } else { Ok(()) }
                }
                Ok(msg) => send(&mut sink, &msg).await,
                // Too slow to keep up: start over from a fresh snapshot, and the watched feed too.
                Err(RecvError::Lagged(_)) => {
                    let mut r = send_snapshot(&s, &mut sink).await;
                    let w = watching.lock().unwrap().clone();
                    if let (Ok(()), Some((h, w))) = (&r, w) {
                        r = send_history(&s, &mut sink, &h, &w).await;
                    }
                    r
                }
                Err(RecvError::Closed) => return,
            },
            Some(o) = out.recv() => match o {
                Out::Json(msg) => send(&mut sink, &msg).await,
                Out::Audio(frame) => sink.send(Message::Binary(frame.into())).await,
            },
            _ = history.notified() => {
                let w = watching.lock().unwrap().clone();
                match w {
                    Some((h, w)) => send_history(&s, &mut sink, &h, &w).await,
                    None => Ok(()),
                }
            }
            _ = ping.tick() => sink.send(Message::Ping(Bytes::new())).await,
        };
        if sent.is_err() {
            return;
        }
    }
}

async fn serve(s: AppState, socket: WebSocket) {
    let _connected = Connected::new(&s.board_connected);
    // Subscribe first so nothing between the snapshot and the loop is missed.
    let rx = s.tx.subscribe();
    let (sink, mut stream) = socket.split();
    let watching: Watching = Arc::default();
    let history = Arc::new(Notify::new());
    let (out_tx, out_rx) = mpsc::channel::<Out>(64);
    let (voice_tx, voice_rx) = mpsc::unbounded_channel::<Voice>();
    let conn = Conn::new(s.voice.clone(), s.voice_cfg, out_tx);
    let queued = Arc::new(Queued::default());
    let mut voice = AbortOnDrop(tokio::spawn(voice_task(conn, voice_rx, queued.clone())));
    let mut writer = AbortOnDrop(tokio::spawn(writer(s.clone(), sink, rx, out_rx, watching.clone(), history.clone())));
    let mut uplink =
        Uplink { tx: voice_tx, queued, stats: s.uplink.clone(), dropped_since_log: 0, last_log: Instant::now() };
    loop {
        tokio::select! {
            // The writer ending means a failed send: the socket is gone.
            _ = &mut writer.0 => break,
            incoming = stream.next() => match incoming {
                Some(Ok(Message::Text(t))) => handle(&s, &watching, &history, &mut uplink, t.as_str()),
                Some(Ok(Message::Binary(b))) => uplink.audio(b.to_vec()),
                Some(Ok(Message::Close(_))) | Some(Err(_)) | None => break,
                Some(Ok(_)) => {}
            }
        }
    }
    // Dropping the aborted voice task drops its `Conn`, which stops any run still going.
    voice.0.abort();
    writer.0.abort();
    let _ = (&mut voice.0).await;
}
