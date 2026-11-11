//! Helpers shared by the integration tests: the board websocket client and in-process voice backends.
#![allow(dead_code)]

use cylon_bot_bridge::app;
use cylon_bot_bridge::auth::Tokens;
use cylon_bot_bridge::http::AppState;
use cylon_bot_bridge::voice::backends::{Brain, Reply, Speech, Stt, Tts, VoiceError};
use futures::StreamExt;
use futures_util::future::BoxFuture;
use serde_json::Value;
use std::collections::VecDeque;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::net::TcpStream;
use tokio_tungstenite::tungstenite::client::IntoClientRequest;
use tokio_tungstenite::tungstenite::{Error as WsError, Message};
use tokio_tungstenite::{MaybeTlsStream, WebSocketStream, connect_async};

pub type Ws = WebSocketStream<MaybeTlsStream<TcpStream>>;

pub const HOST_TOKEN: &str = "host-token";
pub const DEVICE_TOKEN: &str = "device-token";

pub fn state(ask_timeout_ms: u64) -> AppState {
    AppState::new(
        Tokens { host: HOST_TOKEN.into(), device: DEVICE_TOKEN.into() },
        Duration::from_millis(ask_timeout_ms),
        Duration::from_millis(0),
        21600,
    )
}

pub async fn serve(st: AppState) -> std::net::SocketAddr {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    let router = app(st);
    tokio::spawn(async move { axum::serve(listener, router).await.unwrap() });
    addr
}

pub async fn try_connect(addr: std::net::SocketAddr, token: Option<&str>) -> Result<Ws, WsError> {
    let mut r = format!("ws://{addr}/v1/board").into_client_request().unwrap();
    if let Some(t) = token {
        r.headers_mut().insert("authorization", format!("Bearer {t}").parse().unwrap());
    }
    connect_async(r).await.map(|(ws, _)| ws)
}

/// Connects and consumes the greeting, so tests see the state snapshot first.
pub async fn connect(addr: std::net::SocketAddr) -> Ws {
    let mut ws = try_connect(addr, Some(DEVICE_TOKEN)).await.unwrap();
    assert_eq!(next_json(&mut ws).await["t"], "hello");
    ws
}

/// Next JSON text frame, skipping pings and binary frames.
pub async fn next_json(ws: &mut Ws) -> Value {
    loop {
        let m = tokio::time::timeout(Duration::from_secs(3), ws.next()).await.expect("frame").unwrap().unwrap();
        if let Message::Text(t) = m {
            return serde_json::from_str(t.as_str()).unwrap();
        }
    }
}

// ---------- voice fakes ----------


pub struct FakeStt {
    pub results: Mutex<VecDeque<Result<String, VoiceError>>>,
    pub default: String,
    pub calls: AtomicUsize,
    pub seen: Mutex<Vec<usize>>,
}

impl FakeStt {
    pub fn new(default: &str) -> Arc<FakeStt> {
        Arc::new(FakeStt {
            results: Mutex::new(VecDeque::new()),
            default: default.to_string(),
            calls: AtomicUsize::new(0),
            seen: Mutex::new(Vec::new()),
        })
    }
}

impl Stt for FakeStt {
    fn transcribe(&self, pcm16k: Vec<u8>) -> BoxFuture<'static, Result<String, VoiceError>> {
        self.calls.fetch_add(1, Ordering::SeqCst);
        self.seen.lock().unwrap().push(pcm16k.len());
        let r = self
            .results
            .lock()
            .unwrap()
            .pop_front()
            .unwrap_or_else(|| Ok(self.default.clone()));
        Box::pin(async move { r })
    }
}

pub struct FakeTts {
    pub bytes: usize,
    pub hang: bool,
}

impl Tts for FakeTts {
    fn synthesize(&self, _text: String) -> BoxFuture<'static, Result<Speech, VoiceError>> {
        let n = self.bytes;
        let hang = self.hang;
        Box::pin(async move {
            if hang {
                std::future::pending::<()>().await;
            }
            Ok(Speech { sample_rate: 22050, pcm: vec![1; n] })
        })
    }
}

/// Counts a drop that happens before the stream ended normally.
pub struct StopGuard {
    pub stops: Arc<AtomicUsize>,
    pub armed: bool,
}

impl Drop for StopGuard {
    fn drop(&mut self) {
        if self.armed {
            self.stops.fetch_add(1, Ordering::SeqCst);
        }
    }
}

pub struct FakeBrain {
    /// (delay before the delta, delta)
    pub script: Vec<(Duration, String)>,
    pub hang: bool,
    /// After the script, fail the stream (after 10 ms) instead of ending it.
    pub error: bool,
    /// The first this-many asks hang after their script.
    pub hang_first: AtomicUsize,
    pub asks: AtomicUsize,
    pub stops: Arc<AtomicUsize>,
    pub finished: Arc<AtomicBool>,
    /// How many times `new_session` was called.
    pub resets: AtomicUsize,
}

impl FakeBrain {
    pub fn new(script: &[(u64, &str)], hang: bool) -> Arc<FakeBrain> {
        Self::make(script, hang, false, 0)
    }

    pub fn failing(script: &[(u64, &str)]) -> Arc<FakeBrain> {
        Self::make(script, false, true, 0)
    }

    pub fn hang_first(script: &[(u64, &str)], n: usize) -> Arc<FakeBrain> {
        Self::make(script, false, false, n)
    }

    pub fn make(script: &[(u64, &str)], hang: bool, error: bool, hang_first: usize) -> Arc<FakeBrain> {
        Arc::new(FakeBrain {
            error,
            hang_first: AtomicUsize::new(hang_first),
            script: script.iter().map(|(ms, s)| (Duration::from_millis(*ms), s.to_string())).collect(),
            hang,
            asks: AtomicUsize::new(0),
            stops: Arc::new(AtomicUsize::new(0)),
            finished: Arc::new(AtomicBool::new(false)),
            resets: AtomicUsize::new(0),
        })
    }
}

impl Brain for FakeBrain {
    fn new_session(&self) {
        self.resets.fetch_add(1, Ordering::SeqCst);
    }

    fn ask(&self, _text: String) -> BoxFuture<'static, Result<Reply, VoiceError>> {
        self.asks.fetch_add(1, Ordering::SeqCst);
        let script = self.script.clone();
        let hang = self.hang || self.hang_first.fetch_update(Ordering::SeqCst, Ordering::SeqCst, |n| n.checked_sub(1)).is_ok();
        let error = self.error;
        let guard = StopGuard { stops: self.stops.clone(), armed: true };
        let finished = self.finished.clone();
        Box::pin(async move {
            let state = (0usize, guard);
            let deltas = futures_util::stream::unfold(state, move |(i, mut guard)| {
                let script = script.clone();
                let finished = finished.clone();
                async move {
                    if let Some((delay, text)) = script.get(i).cloned() {
                        tokio::time::sleep(delay).await;
                        return Some((Ok(text), (i + 1, guard)));
                    }
                    if hang {
                        std::future::pending::<()>().await;
                    }
                    if error && i == script.len() {
                        tokio::time::sleep(Duration::from_millis(10)).await;
                        return Some((Err(VoiceError::Unavailable("boom".into())), (i + 1, guard)));
                    }
                    guard.armed = false;
                    drop(guard);
                    finished.store(true, Ordering::SeqCst);
                    None
                }
            })
            .boxed();
            Ok(Reply { deltas })
        })
    }
}
