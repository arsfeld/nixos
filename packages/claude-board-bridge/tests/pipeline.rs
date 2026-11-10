//! The per-connection voice pipeline against in-process fake backends.

use claude_board_bridge::protocol::{
    AUDIO_HEADER_LEN, BoardMsg, ClientMsg, DOWNLINK_CHUNK_MAX, MAX_UTTERANCE_BYTES, Mood, decode_audio,
    encode_audio,
};
use claude_board_bridge::voice::backends::{
    Backends, Brain, Reply, Speech, Stt, Tts, VoiceError,
};
use claude_board_bridge::voice::{Conn, Out, VoiceConfig};
use futures_util::StreamExt;
use futures_util::future::BoxFuture;
use std::collections::VecDeque;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::sync::mpsc;

// ---------- fakes ----------

struct FakeStt {
    results: Mutex<VecDeque<Result<String, VoiceError>>>,
    default: String,
    calls: AtomicUsize,
    seen: Mutex<Vec<usize>>,
}

impl FakeStt {
    fn new(default: &str) -> Arc<FakeStt> {
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

struct FakeTts {
    bytes: usize,
    hang: bool,
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
struct StopGuard {
    stops: Arc<AtomicUsize>,
    armed: bool,
}

impl Drop for StopGuard {
    fn drop(&mut self) {
        if self.armed {
            self.stops.fetch_add(1, Ordering::SeqCst);
        }
    }
}

struct FakeBrain {
    /// (delay before the delta, delta)
    script: Vec<(Duration, String)>,
    hang: bool,
    /// After the script, fail the stream (after 10 ms) instead of ending it.
    error: bool,
    /// The first this-many asks hang after their script.
    hang_first: AtomicUsize,
    asks: AtomicUsize,
    stops: Arc<AtomicUsize>,
    finished: Arc<AtomicBool>,
}

impl FakeBrain {
    fn new(script: &[(u64, &str)], hang: bool) -> Arc<FakeBrain> {
        Self::make(script, hang, false, 0)
    }

    fn failing(script: &[(u64, &str)]) -> Arc<FakeBrain> {
        Self::make(script, false, true, 0)
    }

    fn hang_first(script: &[(u64, &str)], n: usize) -> Arc<FakeBrain> {
        Self::make(script, false, false, n)
    }

    fn make(script: &[(u64, &str)], hang: bool, error: bool, hang_first: usize) -> Arc<FakeBrain> {
        Arc::new(FakeBrain {
            error,
            hang_first: AtomicUsize::new(hang_first),
            script: script.iter().map(|(ms, s)| (Duration::from_millis(*ms), s.to_string())).collect(),
            hang,
            asks: AtomicUsize::new(0),
            stops: Arc::new(AtomicUsize::new(0)),
            finished: Arc::new(AtomicBool::new(false)),
        })
    }
}

impl Brain for FakeBrain {
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

// ---------- helpers ----------

struct Rig {
    conn: Conn,
    rx: mpsc::Receiver<Out>,
    stt: Arc<FakeStt>,
    brain: Arc<FakeBrain>,
    /// Everything received so far, in order.
    log: Vec<Out>,
}

fn rig(brain: Arc<FakeBrain>, tts_bytes: usize, cfg: VoiceConfig) -> Rig {
    let stt = FakeStt::new("hi");
    rig_with(stt, brain, tts_bytes, cfg)
}

fn rig_with(stt: Arc<FakeStt>, brain: Arc<FakeBrain>, tts_bytes: usize, cfg: VoiceConfig) -> Rig {
    let (tx, rx) = mpsc::channel(256);
    let backends = Arc::new(Backends {
        stt: stt.clone(),
        tts: Arc::new(FakeTts { bytes: tts_bytes, hang: false }),
        brain: brain.clone(),
    });
    Rig { conn: Conn::new(Some(backends), cfg, tx), rx, stt, brain, log: Vec::new() }
}

fn mood(m: Mood) -> Out {
    Out::Json(BoardMsg::Creature { mood: m })
}

impl Rig {
    /// Start, upload `bytes` of audio and end utterance `id`.
    async fn speak(&mut self, id: u32, bytes: usize) {
        self.conn.on_client(&ClientMsg::VoiceStart { utterance: id }).await;
        self.conn.on_audio(&encode_audio(id, &vec![0; bytes]));
        self.conn.on_client(&ClientMsg::VoiceEnd { utterance: id }).await;
    }

    async fn next(&mut self) -> Out {
        let m = tokio::time::timeout(Duration::from_secs(120), self.rx.recv())
            .await
            .expect("timed out waiting for output")
            .expect("channel closed");
        self.log.push(m.clone());
        m
    }

    /// Messages up to and including the next Idle or Offline.
    async fn until_terminal(&mut self) -> Vec<Out> {
        let mut v = Vec::new();
        loop {
            let m = self.next().await;
            let end = m == mood(Mood::Idle) || m == mood(Mood::Offline);
            v.push(m);
            if end {
                return v;
            }
        }
    }

    fn drain(&mut self) -> Vec<Out> {
        let mut v = Vec::new();
        while let Ok(m) = self.rx.try_recv() {
            self.log.push(m.clone());
            v.push(m);
        }
        v
    }
}

fn speak_starts(log: &[Out]) -> usize {
    log.iter().filter(|m| matches!(m, Out::Json(BoardMsg::SpeakStart { .. }))).count()
}

fn speak_ends(log: &[Out]) -> usize {
    log.iter().filter(|m| matches!(m, Out::Json(BoardMsg::SpeakEnd { .. }))).count()
}

/// Every SpeakStart is closed by exactly one SpeakEnd, directly followed by a mood.
fn assert_balanced(log: &[Out]) {
    assert_eq!(speak_starts(log), speak_ends(log), "unbalanced SpeakStart/SpeakEnd in {log:?}");
    for (i, m) in log.iter().enumerate() {
        if matches!(m, Out::Json(BoardMsg::SpeakEnd { .. })) {
            assert!(matches!(log.get(i + 1), Some(Out::Json(BoardMsg::Creature { .. }))), "no mood after SpeakEnd in {log:?}");
        }
    }
}

fn two_sentences() -> Arc<FakeBrain> {
    FakeBrain::new(&[(0, "Hello there friend. "), (0, "How are you today?")], false)
}

// ---------- tests ----------

#[tokio::test(start_paused = true)]
async fn happy_path_emits_the_messages_in_order() {
    let mut r = rig(two_sentences(), 1000, VoiceConfig::default());
    r.speak(1, 3200).await;
    let got = r.until_terminal().await;
    let n = got.len();
    assert_eq!(got[0], mood(Mood::Thinking));
    assert_eq!(got[1], Out::Json(BoardMsg::Transcript { utterance: 1, text: "hi".into() }));
    assert_eq!(
        got[2],
        Out::Json(BoardMsg::ReplyText { utterance: 1, text: "Hello there friend. How are you today?".into() })
    );
    assert_eq!(got[3], mood(Mood::Speaking));
    assert_eq!(got[4], Out::Json(BoardMsg::SpeakStart { utterance: 1, sample_rate: 22050 }));
    let mut pcm = 0;
    for m in &got[5..n - 2] {
        let Out::Audio(f) = m else { panic!("expected audio, got {m:?}") };
        let (id, body) = decode_audio(f).unwrap();
        assert_eq!(id, 1);
        pcm += body.len();
    }
    assert_eq!(pcm, 2000);
    assert_eq!(got[n - 2], Out::Json(BoardMsg::SpeakEnd { utterance: 1 }));
    assert_eq!(got[n - 1], mood(Mood::Idle));
    assert_eq!(r.brain.stops.load(Ordering::SeqCst), 0);
}

#[tokio::test(start_paused = true)]
async fn first_audio_arrives_before_the_reply_ends() {
    let brain = FakeBrain::new(&[(0, "Hello there friend. "), (10_000, "Second sentence here.")], false);
    let mut r = rig(brain, 1000, VoiceConfig::default());
    r.speak(1, 3200).await;
    loop {
        if let Out::Audio(_) = r.next().await {
            break;
        }
    }
    assert!(!r.brain.finished.load(Ordering::SeqCst), "reply already ended at first audio");
    let rest = r.until_terminal().await;
    assert_eq!(rest.last(), Some(&mood(Mood::Idle)));
    assert!(r.brain.finished.load(Ordering::SeqCst));
}

#[tokio::test(start_paused = true)]
async fn no_backends_reports_offline() {
    let (tx, mut rx) = mpsc::channel(16);
    let mut conn = Conn::new(None, VoiceConfig::default(), tx);
    conn.on_client(&ClientMsg::VoiceStart { utterance: 1 }).await;
    assert_eq!(rx.recv().await, Some(mood(Mood::Offline)));
    conn.on_audio(&encode_audio(1, &[0; 3200]));
    conn.on_client(&ClientMsg::VoiceEnd { utterance: 1 }).await;
    tokio::time::sleep(Duration::from_secs(1)).await;
    assert!(rx.try_recv().is_err());
}

#[tokio::test(start_paused = true)]
async fn empty_transcript_calls_no_brain() {
    let stt = FakeStt::new("");
    let mut r = rig_with(stt, two_sentences(), 1000, VoiceConfig::default());
    r.speak(1, 3200).await;
    let got = r.until_terminal().await;
    assert_eq!(got, vec![mood(Mood::Thinking), mood(Mood::Idle)]);
    assert_eq!(r.brain.asks.load(Ordering::SeqCst), 0);
}

#[tokio::test(start_paused = true)]
async fn stt_failure_reports_offline_and_returns_to_idle_later() {
    let stt = FakeStt::new("hi");
    stt.results.lock().unwrap().push_back(Err(VoiceError::Unavailable("down".into())));
    let mut r = rig_with(stt, two_sentences(), 1000, VoiceConfig::default());
    r.speak(1, 3200).await;
    assert_eq!(r.until_terminal().await, vec![mood(Mood::Thinking), mood(Mood::Offline)]);
    r.speak(2, 3200).await;
    let got = r.until_terminal().await;
    assert_eq!(got.last(), Some(&mood(Mood::Idle)));
    assert!(!got.contains(&mood(Mood::Offline)));
    assert!(got.contains(&Out::Json(BoardMsg::Transcript { utterance: 2, text: "hi".into() })));
}

#[tokio::test(start_paused = true)]
async fn brain_timeout_reports_offline_and_stops_the_run() {
    let brain = FakeBrain::new(&[], true);
    let cfg = VoiceConfig { reply_timeout: Duration::from_millis(50), ..VoiceConfig::default() };
    let mut r = rig(brain, 1000, cfg);
    r.speak(1, 3200).await;
    let got = r.until_terminal().await;
    assert_eq!(got.last(), Some(&mood(Mood::Offline)));
    assert_eq!(r.brain.stops.load(Ordering::SeqCst), 1, "the run was not stopped");
}

#[tokio::test(start_paused = true)]
async fn brain_timeout_then_next_utterance_returns_to_idle() {
    let brain = FakeBrain::hang_first(&[(0, "Hello there friend. ")], 1);
    let cfg = VoiceConfig { reply_timeout: Duration::from_millis(50), ..VoiceConfig::default() };
    let mut r = rig(brain, 1000, cfg);
    r.speak(1, 3200).await;
    assert_eq!(r.until_terminal().await.last(), Some(&mood(Mood::Offline)));
    r.speak(2, 3200).await;
    let got = r.until_terminal().await;
    assert_eq!(got.last(), Some(&mood(Mood::Idle)));
    assert!(!got.contains(&mood(Mood::Offline)));
    assert_balanced(&r.log);
}

#[tokio::test(start_paused = true)]
async fn timeout_mid_speech_sends_speakend_then_offline() {
    let brain = FakeBrain::new(&[(0, "Hello there friend. ")], true);
    let cfg = VoiceConfig { reply_timeout: Duration::from_millis(50), ..VoiceConfig::default() };
    let mut r = rig(brain, 1000, cfg);
    r.speak(1, 3200).await;
    let got = r.until_terminal().await;
    let n = got.len();
    assert_eq!(got[n - 2], Out::Json(BoardMsg::SpeakEnd { utterance: 1 }));
    assert_eq!(got[n - 1], mood(Mood::Offline));
    assert_eq!(speak_starts(&got), 1);
    assert_balanced(&r.log);
}

#[tokio::test(start_paused = true)]
async fn brain_error_mid_speech_sends_speakend_then_offline() {
    let brain = FakeBrain::failing(&[(0, "Hello there friend. ")]);
    let mut r = rig(brain, 1000, VoiceConfig::default());
    r.speak(1, 3200).await;
    let got = r.until_terminal().await;
    let n = got.len();
    assert_eq!(speak_starts(&got), 1);
    assert_eq!(got[n - 2], Out::Json(BoardMsg::SpeakEnd { utterance: 1 }));
    assert_eq!(got[n - 1], mood(Mood::Offline));
    assert_balanced(&r.log);
}

#[tokio::test(start_paused = true)]
async fn hung_tts_is_bounded_by_the_reply_timeout() {
    let (tx, rx) = mpsc::channel(256);
    let stt = FakeStt::new("hi");
    let brain = FakeBrain::new(&[(0, "Hello there friend. ")], false);
    let backends = Arc::new(Backends {
        stt: stt.clone(),
        tts: Arc::new(FakeTts { bytes: 1000, hang: true }),
        brain: brain.clone(),
    });
    let cfg = VoiceConfig { reply_timeout: Duration::from_millis(50), ..VoiceConfig::default() };
    let conn = Conn::new(Some(backends), cfg, tx);
    let mut r = Rig { conn, rx, stt, brain, log: Vec::new() };
    r.speak(1, 3200).await;
    let got = r.until_terminal().await;
    assert_eq!(got.last(), Some(&mood(Mood::Offline)));
    assert_eq!(speak_starts(&got), 0);
}

async fn mid_reply_rig() -> Rig {
    // One sentence, then the reply never ends.
    let brain = FakeBrain::new(&[(0, "Hello there friend. ")], true);
    let mut r = rig(brain, 1000, VoiceConfig::default());
    r.speak(1, 3200).await;
    loop {
        if let Out::Audio(_) = r.next().await {
            break;
        }
    }
    r
}

#[tokio::test(start_paused = true)]
async fn cancel_aborts_speech_and_stops_the_run() {
    let mut r = mid_reply_rig().await;
    r.conn.on_client(&ClientMsg::Cancel { utterance: 1 }).await;
    tokio::time::sleep(Duration::from_secs(1)).await;
    assert_eq!(r.brain.stops.load(Ordering::SeqCst), 1);
}

#[tokio::test(start_paused = true)]
async fn cancel_mid_speech_sends_speakend_then_idle() {
    let mut r = mid_reply_rig().await;
    r.conn.on_client(&ClientMsg::Cancel { utterance: 1 }).await;
    tokio::time::sleep(Duration::from_secs(1)).await;
    assert_eq!(r.drain(), vec![Out::Json(BoardMsg::SpeakEnd { utterance: 1 }), mood(Mood::Idle)]);
    assert_balanced(&r.log);
}

#[tokio::test(start_paused = true)]
async fn replacing_voicestart_closes_the_old_turn_and_sends_idle() {
    let mut r = mid_reply_rig().await;
    r.conn.on_client(&ClientMsg::VoiceStart { utterance: 2 }).await;
    tokio::time::sleep(Duration::from_secs(1)).await;
    assert_eq!(r.drain(), vec![Out::Json(BoardMsg::SpeakEnd { utterance: 1 }), mood(Mood::Idle)]);
    assert_eq!(r.brain.stops.load(Ordering::SeqCst), 1);
    assert_balanced(&r.log);
}

#[tokio::test(start_paused = true)]
async fn speakend_is_sent_exactly_once_per_speakstart() {
    let mut r = mid_reply_rig().await;
    r.conn.on_client(&ClientMsg::Cancel { utterance: 1 }).await;
    r.conn.on_client(&ClientMsg::Cancel { utterance: 1 }).await;
    r.conn.on_client(&ClientMsg::VoiceStart { utterance: 2 }).await;
    tokio::time::sleep(Duration::from_secs(1)).await;
    r.drain();
    assert_eq!(speak_starts(&r.log), 1);
    assert_eq!(speak_ends(&r.log), 1);
    assert_balanced(&r.log);
}

#[tokio::test(start_paused = true)]
async fn stale_id_cancel_leaves_the_current_run_alone() {
    let mut r = mid_reply_rig().await;
    r.conn.on_client(&ClientMsg::Cancel { utterance: 99 }).await;
    tokio::time::sleep(Duration::from_secs(1)).await;
    assert!(r.drain().is_empty());
    assert_eq!(r.brain.stops.load(Ordering::SeqCst), 0);
}

#[tokio::test(start_paused = true)]
async fn voiceend_with_the_wrong_id_leaves_the_recording_in_place() {
    let mut r = rig(two_sentences(), 1000, VoiceConfig::default());
    r.conn.on_client(&ClientMsg::VoiceStart { utterance: 1 }).await;
    r.conn.on_audio(&encode_audio(1, &[0; 1600]));
    r.conn.on_client(&ClientMsg::VoiceEnd { utterance: 2 }).await;
    r.conn.on_audio(&encode_audio(1, &[0; 1600]));
    r.conn.on_client(&ClientMsg::VoiceEnd { utterance: 1 }).await;
    r.until_terminal().await;
    assert_eq!(*r.stt.seen.lock().unwrap(), vec![3200]);
}

#[tokio::test(start_paused = true)]
async fn every_chunk_is_sample_aligned() {
    let brain = FakeBrain::new(&[(0, "One long sentence here.")], false);
    let mut r = rig(brain, 100_001, VoiceConfig::default());
    r.speak(1, 3200).await;
    let got = r.until_terminal().await;
    let mut n = 0;
    for m in &got {
        if let Out::Audio(f) = m {
            assert_eq!((f.len() - AUDIO_HEADER_LEN) % 2, 0);
            n += 1;
        }
    }
    assert!(n > 0);
}

#[tokio::test(start_paused = true)]
async fn rate_limiter_frees_a_slot_at_exactly_60_seconds() {
    let mut r = rig(FakeBrain::new(&[(0, "Fine thanks.")], false), 100, VoiceConfig::default());
    for id in 1..=10 {
        r.speak(id, 3200).await;
        r.until_terminal().await;
    }
    tokio::time::sleep(Duration::from_millis(59_999)).await;
    r.speak(11, 3200).await;
    assert_eq!(r.until_terminal().await, vec![mood(Mood::Idle)]);
    tokio::time::sleep(Duration::from_millis(1)).await;
    r.speak(12, 3200).await;
    assert_eq!(r.until_terminal().await[0], mood(Mood::Thinking));
}

#[tokio::test(start_paused = true)]
async fn dropping_conn_mid_reply_stops_the_run_and_sends_nothing_more() {
    let mut r = mid_reply_rig().await;
    drop(r.conn);
    tokio::time::sleep(Duration::from_secs(1)).await;
    assert_eq!(r.brain.stops.load(Ordering::SeqCst), 1);
    // Best effort: the speaking turn is closed, then nothing more and the channel closes.
    assert_eq!(r.rx.try_recv(), Ok(Out::Json(BoardMsg::SpeakEnd { utterance: 1 })));
    assert_eq!(r.rx.try_recv(), Ok(mood(Mood::Idle)));
    assert!(matches!(r.rx.try_recv(), Err(mpsc::error::TryRecvError::Disconnected)));
}

#[tokio::test(start_paused = true)]
async fn audio_chunks_never_exceed_the_frame_limit() {
    let brain = FakeBrain::new(&[(0, "One long sentence here.")], false);
    let mut r = rig(brain, 200_000, VoiceConfig::default());
    r.speak(1, 3200).await;
    let got = r.until_terminal().await;
    let mut frames = 0;
    let mut pcm = 0;
    for m in &got {
        if let Out::Audio(f) = m {
            assert!(f.len() <= DOWNLINK_CHUNK_MAX, "frame of {} bytes", f.len());
            assert!(f.len() > AUDIO_HEADER_LEN);
            frames += 1;
            pcm += f.len() - AUDIO_HEADER_LEN;
        }
    }
    assert_eq!(pcm, 200_000);
    assert!(frames >= 7);
}

#[tokio::test(start_paused = true)]
async fn oversize_utterance_is_dropped() {
    let mut r = rig(two_sentences(), 1000, VoiceConfig::default());
    r.conn.on_client(&ClientMsg::VoiceStart { utterance: 1 }).await;
    let mut sent = 0;
    while sent <= MAX_UTTERANCE_BYTES {
        r.conn.on_audio(&encode_audio(1, &[0; 100_000]));
        sent += 100_000;
    }
    r.conn.on_client(&ClientMsg::VoiceEnd { utterance: 1 }).await;
    assert_eq!(r.until_terminal().await, vec![mood(Mood::Idle)]);
    assert_eq!(r.stt.calls.load(Ordering::SeqCst), 0);
}

#[tokio::test(start_paused = true)]
async fn wrong_utterance_id_audio_is_ignored() {
    let mut r = rig(two_sentences(), 1000, VoiceConfig::default());
    r.conn.on_client(&ClientMsg::VoiceStart { utterance: 1 }).await;
    r.conn.on_audio(&encode_audio(2, &[0; 500]));
    r.conn.on_audio(&[1, 2]); // shorter than the header
    r.conn.on_audio(&encode_audio(1, &[0; 3200]));
    r.conn.on_client(&ClientMsg::VoiceEnd { utterance: 1 }).await;
    r.until_terminal().await;
    assert_eq!(*r.stt.seen.lock().unwrap(), vec![3200]);
}

#[tokio::test(start_paused = true)]
async fn eleventh_utterance_in_a_minute_is_refused() {
    let mut r = rig(FakeBrain::new(&[(0, "Fine thanks.")], false), 100, VoiceConfig::default());
    for id in 1..=10 {
        r.speak(id, 3200).await;
        let got = r.until_terminal().await;
        assert_eq!(got.last(), Some(&mood(Mood::Idle)));
    }
    r.speak(11, 3200).await;
    assert_eq!(r.until_terminal().await, vec![mood(Mood::Idle)]);
    assert_eq!(r.stt.calls.load(Ordering::SeqCst), 10);
    // Once the window rolls over, a new utterance is accepted again.
    tokio::time::sleep(Duration::from_secs(61)).await;
    r.speak(12, 3200).await;
    let got = r.until_terminal().await;
    assert_eq!(got[0], mood(Mood::Thinking));
    assert_eq!(r.stt.calls.load(Ordering::SeqCst), 11);
}
