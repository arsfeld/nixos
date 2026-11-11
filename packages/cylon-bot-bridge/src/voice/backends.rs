//! HTTP clients for the three voice backends: whisper.cpp (speech to text),
//! Piper (text to speech) and Hermes (the creature's brain). All three are
//! loopback plain HTTP. Transcript and reply text is never logged.

use futures_util::future::BoxFuture;
use futures_util::stream::BoxStream;
use futures_util::{StreamExt, TryStreamExt};
use serde_json::Value;
use super::session::SessionId;
use std::sync::Arc;
use std::time::Duration;

#[derive(Debug)]
pub enum VoiceError {
    Unavailable(String),
    Timeout,
    Rejected(String),
}

#[derive(Debug)]
pub struct Speech {
    pub sample_rate: u32,
    pub pcm: Vec<u8>,
}

pub struct Reply {
    pub deltas: BoxStream<'static, Result<String, VoiceError>>,
}

pub trait Stt: Send + Sync {
    fn transcribe(&self, pcm16k: Vec<u8>) -> BoxFuture<'static, Result<String, VoiceError>>;
}

pub trait Tts: Send + Sync {
    fn synthesize(&self, text: String) -> BoxFuture<'static, Result<Speech, VoiceError>>;
}

pub trait Brain: Send + Sync {
    fn ask(&self, text: String) -> BoxFuture<'static, Result<Reply, VoiceError>>;
    /// Start a fresh conversation. Fakes that keep no session ignore it.
    fn new_session(&self) {}
}

pub struct Backends {
    pub stt: Arc<dyn Stt>,
    pub tts: Arc<dyn Tts>,
    pub brain: Arc<dyn Brain>,
}

fn map_err(e: reqwest::Error) -> VoiceError {
    if e.is_timeout() {
        VoiceError::Timeout
    } else {
        // Strip the URL: it is harmless, but keep messages short and text-free.
        VoiceError::Unavailable(e.without_url().to_string())
    }
}

fn map_status(status: reqwest::StatusCode) -> Result<(), VoiceError> {
    if status.is_success() {
        Ok(())
    } else if status.is_client_error() {
        Err(VoiceError::Rejected(format!("status {status}")))
    } else {
        Err(VoiceError::Unavailable(format!("status {status}")))
    }
}

fn short_client() -> reqwest::Client {
    reqwest::Client::builder()
        .connect_timeout(Duration::from_secs(15))
        .timeout(Duration::from_secs(60))
        .build()
        .expect("reqwest client")
}

fn trim_base(base: String) -> String {
    base.trim_end_matches('/').to_string()
}

// ---------- whisper.cpp ----------

pub struct WhisperHttp {
    base: String,
    client: reqwest::Client,
}

impl WhisperHttp {
    pub fn new(base_url: String) -> Self {
        Self { base: trim_base(base_url), client: short_client() }
    }
}

fn wav16k(pcm: &[u8]) -> Vec<u8> {
    let mut v = Vec::with_capacity(44 + pcm.len());
    v.extend_from_slice(b"RIFF");
    v.extend_from_slice(&(36 + pcm.len() as u32).to_le_bytes());
    v.extend_from_slice(b"WAVEfmt ");
    v.extend_from_slice(&16u32.to_le_bytes());
    v.extend_from_slice(&1u16.to_le_bytes()); // PCM
    v.extend_from_slice(&1u16.to_le_bytes()); // mono
    v.extend_from_slice(&16000u32.to_le_bytes());
    v.extend_from_slice(&32000u32.to_le_bytes());
    v.extend_from_slice(&2u16.to_le_bytes());
    v.extend_from_slice(&16u16.to_le_bytes());
    v.extend_from_slice(b"data");
    v.extend_from_slice(&(pcm.len() as u32).to_le_bytes());
    v.extend_from_slice(pcm);
    v
}

impl Stt for WhisperHttp {
    fn transcribe(&self, pcm16k: Vec<u8>) -> BoxFuture<'static, Result<String, VoiceError>> {
        let client = self.client.clone();
        let url = format!("{}/inference", self.base);
        Box::pin(async move {
            let part = reqwest::multipart::Part::bytes(wav16k(&pcm16k))
                .file_name("audio.wav")
                .mime_str("audio/wav")
                .map_err(map_err)?;
            let form = reqwest::multipart::Form::new()
                .part("file", part)
                .text("response_format", "json")
                .text("temperature", "0");
            let resp = client.post(url).multipart(form).send().await.map_err(map_err)?;
            map_status(resp.status())?;
            let v: Value = resp.json().await.map_err(map_err)?;
            let text = v["text"]
                .as_str()
                .ok_or_else(|| VoiceError::Unavailable("whisper reply has no text".into()))?;
            Ok(text.split_whitespace().collect::<Vec<_>>().join(" "))
        })
    }
}

// ---------- Piper ----------

pub struct PiperHttp {
    base: String,
    client: reqwest::Client,
}

impl PiperHttp {
    pub fn new(base_url: String) -> Self {
        Self { base: trim_base(base_url), client: short_client() }
    }
}

/// Sample rate and PCM bytes of a RIFF/WAVE file, read from its chunks.
fn parse_wav(b: &[u8]) -> Option<(u32, Vec<u8>)> {
    if b.len() < 12 || &b[0..4] != b"RIFF" || &b[8..12] != b"WAVE" {
        return None;
    }
    let mut rate = None;
    let mut at = 12;
    while at + 8 <= b.len() {
        let id = &b[at..at + 4];
        let size = u32::from_le_bytes(b[at + 4..at + 8].try_into().ok()?) as usize;
        let body = at + 8;
        if id == b"fmt " && body + 8 <= b.len() {
            rate = Some(u32::from_le_bytes(b[body + 4..body + 8].try_into().ok()?));
        } else if id == b"data" {
            // Streaming writers may leave the size as 0 or 0xFFFFFFFF: take the rest.
            let end = if size == 0 || body.saturating_add(size) > b.len() {
                b.len()
            } else {
                body + size
            };
            return Some((rate?, b[body..end].to_vec()));
        }
        at = body.checked_add(size)?.checked_add(size & 1)?;
    }
    None
}

impl Tts for PiperHttp {
    fn synthesize(&self, text: String) -> BoxFuture<'static, Result<Speech, VoiceError>> {
        let client = self.client.clone();
        let url = format!("{}/synthesize", self.base);
        Box::pin(async move {
            let resp = client
                .post(url)
                .json(&serde_json::json!({ "text": text }))
                .send()
                .await
                .map_err(map_err)?;
            map_status(resp.status())?;
            let bytes = resp.bytes().await.map_err(map_err)?;
            let (sample_rate, pcm) = parse_wav(&bytes)
                .ok_or_else(|| VoiceError::Unavailable("piper reply is not a WAV".into()))?;
            Ok(Speech { sample_rate, pcm })
        })
    }
}

// ---------- Hermes ----------

/// Deadline for the `POST /v1/runs` call and for the event stream to open.
pub const HERMES_POST_TIMEOUT: Duration = Duration::from_secs(30);
/// Longest silence tolerated between two chunks of the event stream. There is
/// deliberately no total deadline: the pipeline owns the overall reply timeout.
pub const HERMES_IDLE_TIMEOUT: Duration = Duration::from_secs(30);
/// Longest pending SSE frame kept in memory.
const MAX_EVENT_BYTES: usize = 1 << 20;

pub struct HermesHttp {
    base: String,
    key: String,
    session: Arc<SessionId>,
    client: reqwest::Client,
    post_timeout: Duration,
    idle_timeout: Duration,
}

impl HermesHttp {
    pub fn new(base_url: String, api_key: String, session: Arc<SessionId>) -> Self {
        // No overall timeout: the event stream lives as long as the reply.
        let client = reqwest::Client::builder()
            .connect_timeout(Duration::from_secs(15))
            .build()
            .expect("reqwest client");
        Self {
            base: trim_base(base_url),
            key: api_key,
            session,
            client,
            post_timeout: HERMES_POST_TIMEOUT,
            idle_timeout: HERMES_IDLE_TIMEOUT,
        }
    }

    pub fn with_timeouts(mut self, post: Duration, idle: Duration) -> Self {
        self.post_timeout = post;
        self.idle_timeout = idle;
        self
    }
}

/// Stops the Hermes run when dropped while still armed. Disarmed once the run
/// ended normally. Safe outside a tokio runtime (then it does nothing).
struct StopGuard {
    client: reqwest::Client,
    url: String,
    key: String,
    armed: bool,
}

impl Drop for StopGuard {
    fn drop(&mut self) {
        if !self.armed {
            return;
        }
        let Ok(handle) = tokio::runtime::Handle::try_current() else { return };
        let (client, url, key) = (self.client.clone(), self.url.clone(), self.key.clone());
        handle.spawn(async move {
            let _ = client
                .post(url)
                .bearer_auth(key)
                .json(&serde_json::json!({}))
                .timeout(Duration::from_secs(10))
                .send()
                .await;
        });
    }
}

struct RunState {
    bytes: BoxStream<'static, Result<bytes::Bytes, reqwest::Error>>,
    /// Pending bytes, with `\r\n` and lone `\r` already normalised to `\n`.
    buf: Vec<u8>,
    /// The last byte seen was a `\r` (so a `\n` starting the next chunk is its pair).
    after_cr: bool,
    guard: StopGuard,
    idle: Duration,
    done: bool,
}

impl RunState {
    fn feed(&mut self, chunk: &[u8]) {
        for &b in chunk {
            if self.after_cr && b == b'\n' {
                self.after_cr = false;
                continue;
            }
            self.after_cr = b == b'\r';
            self.buf.push(if b == b'\r' { b'\n' } else { b });
        }
    }
}

enum Frame {
    Delta(String),
    End,
    Failed(String),
    Ignore,
}

fn parse_frame(frame: &str) -> Frame {
    let data: String = frame
        .lines()
        .filter_map(|l| l.strip_prefix("data:"))
        .map(|d| d.strip_prefix(' ').unwrap_or(d))
        .collect::<Vec<_>>()
        .join("\n");
    if data.is_empty() {
        return Frame::Ignore;
    }
    let Ok(v) = serde_json::from_str::<Value>(&data) else { return Frame::Ignore };
    match v["event"].as_str() {
        Some("message.delta") => match v["delta"].as_str() {
            Some(d) if !d.is_empty() => Frame::Delta(d.to_string()),
            _ => Frame::Ignore,
        },
        Some("run.completed") | Some("run.cancelled") => Frame::End,
        Some("run.failed") => Frame::Failed(match v["error"].as_str() {
            Some(e) if !e.is_empty() => format!("hermes run failed: {e}"),
            _ => "hermes run failed".to_string(),
        }),
        _ => Frame::Ignore,
    }
}

impl Brain for HermesHttp {
    fn new_session(&self) {
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_secs() as i64)
            .unwrap_or(0);
        self.session.reset(now);
    }

    fn ask(&self, text: String) -> BoxFuture<'static, Result<Reply, VoiceError>> {
        let (client, base, key, session) =
            (self.client.clone(), self.base.clone(), self.key.clone(), self.session.current());
        let (post_timeout, idle) = (self.post_timeout, self.idle_timeout);
        Box::pin(async move {
            let resp = client
                .post(format!("{base}/v1/runs"))
                .bearer_auth(&key)
                .json(&serde_json::json!({ "input": text, "session_id": session }))
                .timeout(post_timeout)
                .send()
                .await
                .map_err(map_err)?;
            map_status(resp.status())?;
            let v: Value = resp.json().await.map_err(map_err)?;
            let run_id = v["run_id"]
                .as_str()
                .ok_or_else(|| VoiceError::Unavailable("hermes reply has no run_id".into()))?
                .to_string();
            let guard = StopGuard {
                client: client.clone(),
                url: format!("{base}/v1/runs/{run_id}/stop"),
                key: key.clone(),
                armed: true,
            };
            // No request timeout here (it would cover the whole body); only the
            // wait for the stream to open is bounded.
            let resp = tokio::time::timeout(
                post_timeout,
                client.get(format!("{base}/v1/runs/{run_id}/events")).bearer_auth(&key).send(),
            )
            .await;
            // On failure here the guard drops armed and stops the run.
            let resp = resp.map_err(|_| VoiceError::Timeout)?.map_err(map_err)?;
            map_status(resp.status())?;
            let state = RunState {
                bytes: resp.bytes_stream().boxed(),
                buf: Vec::new(),
                after_cr: false,
                guard,
                idle,
                done: false,
            };
            let deltas = futures_util::stream::try_unfold(state, |mut st| async move {
                loop {
                    if st.done {
                        return Ok(None);
                    }
                    // Complete frames are separated by a blank line.
                    if let Some(i) = st.buf.windows(2).position(|w| w == b"\n\n") {
                        let raw: Vec<u8> = st.buf.drain(..i + 2).collect();
                        let frame = String::from_utf8_lossy(&raw);
                        match parse_frame(&frame) {
                            Frame::Delta(d) => return Ok(Some((d, st))),
                            Frame::End => {
                                st.guard.armed = false;
                                st.done = true;
                            }
                            Frame::Failed(msg) => {
                                // Deliberate: the guard stays armed, so the run is stopped
                                // when the Reply drops. A stop on a failed run is harmless
                                // and covers a run that failed but is still winding down.
                                return Err(VoiceError::Rejected(msg));
                            }
                            Frame::Ignore => {}
                        }
                        continue;
                    }
                    if st.buf.len() > MAX_EVENT_BYTES {
                        return Err(VoiceError::Rejected("event too large".into()));
                    }
                    // Idle timeout between chunks; the guard stays armed on timeout.
                    let next = tokio::time::timeout(st.idle, st.bytes.try_next())
                        .await
                        .map_err(|_| VoiceError::Timeout)?;
                    match next.map_err(map_err)? {
                        Some(chunk) => st.feed(&chunk),
                        None => {
                            // Stream closed: the run is over either way.
                            st.guard.armed = false;
                            st.done = true;
                        }
                    }
                }
            })
            .boxed();
            Ok(Reply { deltas })
        })
    }
}
