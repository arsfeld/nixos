//! One board connection's voice pipeline: the uploaded utterance goes through
//! speech to text, the brain and text to speech, and the results go back as
//! `Out` messages. Transcript and reply text is never logged.

use super::backends::{Backends, VoiceError};
use super::speech::{SentenceSplitter, chunk_pcm};
use crate::protocol::{
    AUDIO_HEADER_LEN, BoardMsg, ClientMsg, DOWNLINK_CHUNK_MAX, MAX_UTTERANCE_BYTES, Mood, decode_audio,
    encode_audio,
};
use futures_util::StreamExt;
use futures_util::stream::FuturesOrdered;
use std::collections::VecDeque;
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::sync::mpsc::Sender;
use tokio::sync::mpsc::error::TrySendError;
use tokio::task::JoinHandle;
use tokio::time::Instant;

/// What the pipeline hands to the socket writer.
#[derive(Debug, Clone, PartialEq)]
pub enum Out {
    Json(BoardMsg),
    /// A binary audio frame, header included.
    Audio(Vec<u8>),
}

#[derive(Debug, Clone, Copy)]
pub struct VoiceConfig {
    /// Bounds the whole brain-and-speech phase of one utterance.
    pub reply_timeout: Duration,
    /// Accepted `VoiceStart`s allowed in any rolling minute.
    pub max_per_minute: u32,
}

impl Default for VoiceConfig {
    fn default() -> Self {
        VoiceConfig { reply_timeout: Duration::from_secs(60), max_per_minute: 10 }
    }
}

struct Recording {
    id: u32,
    buf: Vec<u8>,
    overflow: bool,
}

/// The utterance a board has been sent `SpeakStart` for and not yet `SpeakEnd`.
/// Shared with the utterance task so it survives the task being aborted.
type Speaking = Arc<Mutex<Option<u32>>>;

fn take_speaking(speaking: &Speaking) -> Option<u32> {
    speaking.lock().ok().and_then(|mut g| g.take())
}

pub struct Conn {
    backends: Option<Arc<Backends>>,
    cfg: VoiceConfig,
    out: Sender<Out>,
    recording: Option<Recording>,
    /// The utterance whose `VoiceStart` was refused, and the mood it was refused with: its `VoiceEnd` (or
    /// `Cancel`) is answered with that mood again, because the board shows thinking from its release.
    refused: Option<(u32, Mood)>,
    running: Option<(u32, JoinHandle<()>)>,
    starts: VecDeque<Instant>,
    speaking: Speaking,
    /// The task delivering control messages that did not fit the channel; see `control`.
    pending: Option<JoinHandle<()>>,
}

/// How long one control message waits for room in the channel before it is given up.
const CONTROL_WAIT: Duration = Duration::from_secs(5);

impl Drop for Conn {
    fn drop(&mut self) {
        if let Some((_, task)) = self.running.take() {
            task.abort();
        }
        if let Some(task) = self.pending.take() {
            task.abort();
        }
        // Best effort: close a speaking turn if the receiver is still there.
        if let Some(utterance) = take_speaking(&self.speaking) {
            let _ = self.out.try_send(Out::Json(BoardMsg::SpeakEnd { utterance }));
            let _ = self.out.try_send(Out::Json(BoardMsg::Creature { mood: Mood::Idle }));
        }
    }
}

impl Conn {
    pub fn new(backends: Option<Arc<Backends>>, cfg: VoiceConfig, out: Sender<Out>) -> Conn {
        Conn { backends, cfg, out, recording: None, refused: None, running: None, starts: VecDeque::new(), speaking: Arc::default(), pending: None }
    }

    fn mood(&mut self, mood: Mood) {
        self.control(vec![BoardMsg::Creature { mood }]);
    }

    /// Sends what `on_client` originates, in order, without ever making the caller wait: waiting would
    /// stall the reader that calls us (and with it every later `Cancel`). A full channel does not
    /// mean the board is not reading, only that it is behind, and a `SpeakStart` must still get its
    /// `SpeakEnd`, so what does not fit goes to a task that waits for room, up to `CONTROL_WAIT`
    /// per message, then gives up: by then the board is evidently not reading. Later control messages
    /// queue behind that task, and so does the next utterance. The utterance task itself keeps its
    /// awaited sends; cancel aborts it.
    fn control(&mut self, msgs: Vec<BoardMsg>) {
        let mut rest = VecDeque::from(msgs);
        if !self.pending.as_ref().is_some_and(|h| !h.is_finished()) {
            while let Some(m) = rest.pop_front() {
                match self.out.try_send(Out::Json(m)) {
                    Ok(()) => {}
                    Err(TrySendError::Full(Out::Json(m))) => {
                        rest.push_front(m);
                        break;
                    }
                    Err(_) => return,
                }
            }
            if rest.is_empty() {
                return;
            }
        }
        let prev = self.pending.take();
        let out = self.out.clone();
        self.pending = Some(tokio::spawn(async move {
            if let Some(prev) = prev {
                let _ = prev.await;
            }
            for m in rest {
                if !matches!(tokio::time::timeout(CONTROL_WAIT, out.send(Out::Json(m))).await, Ok(Ok(()))) {
                    return;
                }
            }
        }));
    }

    /// Stops whatever is recording or running; true if something was live.
    /// The aborted task is joined first, so it cannot enqueue anything after
    /// the `SpeakEnd` sent here for a turn that was speaking.
    async fn stop_all(&mut self) -> bool {
        let mut live = self.recording.take().is_some();
        if let Some((_, task)) = self.running.take() {
            live |= !task.is_finished();
            task.abort();
            let _ = task.await;
        }
        if let Some(utterance) = take_speaking(&self.speaking) {
            live = true;
            self.control(vec![BoardMsg::SpeakEnd { utterance }]);
        }
        live
    }

    pub async fn on_client(&mut self, msg: &ClientMsg) {
        match msg {
            ClientMsg::VoiceStart { utterance } => {
                let was_live = self.stop_all().await;
                self.refused = None;
                if self.backends.is_none() {
                    self.refused = Some((*utterance, Mood::Offline));
                    self.mood(Mood::Offline);
                    return;
                }
                let now = Instant::now();
                while self.starts.front().is_some_and(|t| now.duration_since(*t) >= Duration::from_secs(60)) {
                    self.starts.pop_front();
                }
                if self.starts.len() >= self.cfg.max_per_minute as usize {
                    self.refused = Some((*utterance, Mood::Idle));
                    self.mood(Mood::Idle);
                    return;
                }
                self.starts.push_back(now);
                self.recording = Some(Recording { id: *utterance, buf: Vec::new(), overflow: false });
                if was_live {
                    // The old turn is closed; the board is about to record.
                    self.mood(Mood::Idle);
                }
            }
            ClientMsg::VoiceEnd { utterance } => {
                if let Some((_, mood)) = self.refused.take_if(|(id, _)| id == utterance) {
                    self.mood(mood);
                    return;
                }
                let Some(rec) = self.recording.take_if(|r| r.id == *utterance) else { return };
                let Some(backends) = self.backends.clone() else { return };
                if rec.overflow || rec.buf.is_empty() {
                    self.mood(Mood::Idle);
                    return;
                }
                let task = tokio::spawn(run_utterance(
                    backends,
                    self.out.clone(),
                    self.cfg.reply_timeout,
                    rec.id,
                    rec.buf,
                    self.speaking.clone(),
                    self.pending.take(),
                ));
                self.running = Some((rec.id, task));
            }
            ClientMsg::Cancel { utterance } => {
                if let Some((_, mood)) = self.refused.take_if(|(id, _)| id == utterance) {
                    self.mood(mood);
                    return;
                }
                let mine = self.recording.as_ref().is_some_and(|r| r.id == *utterance)
                    || self.running.as_ref().is_some_and(|(id, _)| id == utterance);
                if mine && self.stop_all().await {
                    self.mood(Mood::Idle);
                }
            }
            _ => {}
        }
    }

    pub fn on_audio(&mut self, frame: &[u8]) {
        let Some(rec) = self.recording.as_mut() else { return };
        let Some((id, pcm)) = decode_audio(frame) else { return };
        if id != rec.id || rec.overflow {
            return;
        }
        if rec.buf.len() + pcm.len() > MAX_UTTERANCE_BYTES {
            rec.overflow = true;
            rec.buf = Vec::new();
            return;
        }
        rec.buf.extend_from_slice(pcm);
    }
}

#[derive(Default)]
struct Timing {
    stt_ms: u128,
    first_delta_ms: u128,
    first_audio_ms: u128,
}

enum Failure {
    /// The receiver is gone: stop quietly.
    Closed,
    Backend,
}

/// The log line for a failed backend call: the stage and the error kind only, never the error's
/// message (it can carry a response body) and never transcript or reply text.
pub fn failure_line(id: u32, stage: &str, err: &VoiceError) -> String {
    let kind = match err {
        VoiceError::Unavailable(_) => "unavailable",
        VoiceError::Timeout => "timeout",
        VoiceError::Rejected(_) => "rejected",
    };
    format!("voice: utt={id} stage={stage} error={kind}")
}

fn backend_failed(id: u32, stage: &str) -> impl FnOnce(VoiceError) -> Failure + '_ {
    move |e| {
        eprintln!("{}", failure_line(id, stage, &e));
        Failure::Backend
    }
}

async fn put(out: &Sender<Out>, msg: Out) -> Result<(), Failure> {
    out.send(msg).await.map_err(|_| Failure::Closed)
}

async fn put_json(out: &Sender<Out>, msg: BoardMsg) -> Result<(), Failure> {
    put(out, Out::Json(msg)).await
}

async fn run_utterance(
    backends: Arc<Backends>,
    out: Sender<Out>,
    reply_timeout: Duration,
    id: u32,
    pcm: Vec<u8>,
    speaking: Speaking,
    after: Option<JoinHandle<()>>,
) {
    // Control messages still waiting for room go first.
    if let Some(after) = after {
        let _ = after.await;
    }
    let start = Instant::now();
    let bytes = pcm.len();
    let mut timing = Timing::default();
    let result = utterance(&backends, &out, &speaking, reply_timeout, id, pcm, start, &mut timing).await;
    eprintln!(
        "voice: utt={id} bytes={bytes} stt_ms={} first_delta_ms={} first_audio_ms={} total_ms={}",
        timing.stt_ms,
        timing.first_delta_ms,
        timing.first_audio_ms,
        start.elapsed().as_millis()
    );
    if matches!(result, Err(Failure::Closed)) {
        return;
    }
    // Every exit path closes a speaking turn before the mood.
    if let Some(utterance) = take_speaking(&speaking) {
        if put_json(&out, BoardMsg::SpeakEnd { utterance }).await.is_err() {
            return;
        }
    }
    let mood = match result {
        Ok(()) => Mood::Idle,
        Err(Failure::Backend) => Mood::Offline,
        Err(Failure::Closed) => return,
    };
    let _ = put_json(&out, BoardMsg::Creature { mood }).await;
}

async fn utterance(
    backends: &Backends,
    out: &Sender<Out>,
    speaking: &Speaking,
    reply_timeout: Duration,
    id: u32,
    pcm: Vec<u8>,
    start: Instant,
    timing: &mut Timing,
) -> Result<(), Failure> {
    put_json(out, BoardMsg::Creature { mood: Mood::Thinking }).await?;
    let text = backends.stt.transcribe(pcm).await.map_err(backend_failed(id, "stt"))?;
    timing.stt_ms = start.elapsed().as_millis();
    if text.trim().is_empty() {
        return Ok(());
    }
    put_json(out, BoardMsg::Transcript { utterance: id, text: text.clone() }).await?;
    match tokio::time::timeout(reply_timeout, reply(backends, out, speaking, id, text, start, timing)).await {
        Ok(r) => r,
        Err(_) => Err(Failure::Backend),
    }
}

/// Streams the brain's reply, speaking each sentence as it completes.
async fn reply(
    backends: &Backends,
    out: &Sender<Out>,
    speaking: &Speaking,
    id: u32,
    text: String,
    start: Instant,
    timing: &mut Timing,
) -> Result<(), Failure> {
    let mut reply = backends.brain.ask(text).await.map_err(backend_failed(id, "brain"))?;
    let mut splitter = SentenceSplitter::new();
    let mut synths = FuturesOrdered::new();
    let mut full = String::new();
    let mut deltas_done = false;
    let mut tts_failed = false;
    let mut started = false;
    let chunk = DOWNLINK_CHUNK_MAX - AUDIO_HEADER_LEN;
    while !(deltas_done && synths.is_empty()) {
        tokio::select! {
            biased;
            d = reply.deltas.next(), if !deltas_done => match d {
                Some(Ok(delta)) => {
                    if timing.first_delta_ms == 0 {
                        timing.first_delta_ms = start.elapsed().as_millis().max(1);
                    }
                    full.push_str(&delta);
                    for s in splitter.push(&delta) {
                        if !tts_failed {
                            synths.push_back(backends.tts.synthesize(s));
                        }
                    }
                }
                Some(Err(e)) => return Err(backend_failed(id, "brain")(e)),
                None => {
                    deltas_done = true;
                    if let Some(s) = splitter.finish() {
                        if !tts_failed {
                            synths.push_back(backends.tts.synthesize(s));
                        }
                    }
                    let full = full.trim();
                    if !full.is_empty() {
                        put_json(out, BoardMsg::ReplyText { utterance: id, text: full.to_string() }).await?;
                    }
                }
            },
            Some(speech) = synths.next(), if !synths.is_empty() => match speech {
                Ok(speech) => {
                    if !started {
                        started = true;
                        timing.first_audio_ms = start.elapsed().as_millis().max(1);
                        put_json(out, BoardMsg::Creature { mood: Mood::Speaking }).await?;
                        put_json(out, BoardMsg::SpeakStart { utterance: id, sample_rate: speech.sample_rate }).await?;
                        // No await between the send completing and this, so an abort cannot split them.
                        if let Ok(mut g) = speaking.lock() {
                            *g = Some(id);
                        }
                    }
                    for part in chunk_pcm(&speech.pcm, chunk) {
                        put(out, Out::Audio(encode_audio(id, part))).await?;
                    }
                }
                Err(e) => {
                    eprintln!("{}", failure_line(id, "tts", &e));
                    // Skip speaking; the reply text still goes out.
                    tts_failed = true;
                    synths = FuturesOrdered::new();
                }
            },
        }
    }
    Ok(())
}
