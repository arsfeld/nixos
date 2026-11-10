//! Press-to-talk capture: a thread that reads the microphone in 100 ms chunks, and a second one that streams them
//! to the bridge, so a slow websocket write never stalls the reads (the I2S DMA buffer holds only about 90 ms).
//!
//! Memory: one 1600-sample chunk buffer (3.2 KB) reused for the whole utterance, and a queue of at most
//! `UPLINK_QUEUE_CHUNKS` frames (PSRAM) between the two threads; each frame is freed after its send; and while a
//! pre-roll waits for its hold, up to `PREROLL_CHUNKS` chunks (PSRAM). Capture and the chime share an I2S clock,
//! handled inside the C component (`bd_mic_open` waits for a chime in progress, and the chime skips itself while
//! the mic is open).
//!
//! Pre-roll: a hold is only recognised 450 ms after the finger lands, so the app starts a capture on touch-down
//! with no utterance (`Capture::preroll`). It records into a ring of the last `PREROLL_CHUNKS` and sends nothing;
//! `begin` gives it the utterance once the hold is accepted (after `voice_start` went out), and the ring is sent
//! first. A touch that turns out to be a tap ends it with `abandon`, which does not wait for the thread.
//!
//! The thread ends on its own after `MAX_UTTERANCE_BYTES` or when the microphone or a send fails; the app
//! learns about it from `Capture::outcome` (and the levels channel closing). The app, not the thread, tells the
//! controller and the bridge, so a failure is a cancel and the limit is a release.

use std::collections::VecDeque;
use std::sync::atomic::{AtomicBool, AtomicU32, AtomicU8, Ordering};
use std::sync::{mpsc, Arc};
use std::thread::JoinHandle;

use claude_board_proto::MAX_UTTERANCE_BYTES;
use claude_board_ui::audio::{chunk_to_frame, rms_level};
use claude_board_ui::controller::Outbox;

use crate::display;
use crate::net::Net;

/// 100 ms at the uplink rate.
const CHUNK_SAMPLES: usize = 1600;

/// Chunks the uplink may lag behind the microphone: 5 s of audio, 160 KB, all in PSRAM (frames are > 512 bytes).
const UPLINK_QUEUE_CHUNKS: usize = 50;

/// Audio kept from before the hold was recognised: 1 s, more than the 450 ms threshold plus the touch latency.
const PREROLL_CHUNKS: usize = 10;

/// Chunks thrown away after the microphone opens, for its power-on click (200 ms).
const POWER_ON_CHUNKS: usize = 2;

/// `Capture::utterance` before `begin`.
const NO_UTTERANCE: u32 = u32::MAX;

/// How a capture ended. `Running` until it has.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Outcome {
    Running,
    /// `MAX_UTTERANCE_BYTES` were sent: treat it as the finger lifting.
    LimitReached,
    /// The microphone could not be opened or read, or a frame could not be sent: cancel the utterance.
    Failed,
    /// `stop` was called.
    Stopped,
}

pub struct Capture {
    stop: Arc<AtomicBool>,
    outcome: Arc<AtomicU8>,
    utterance: Arc<AtomicU32>,
    thread: Option<JoinHandle<()>>,
}

/// A pre-roll that was let go without waiting: `wait` before the microphone is opened again.
pub struct Abandoned(Option<JoinHandle<()>>);

impl Abandoned {
    pub fn wait(mut self) {
        if let Some(t) = self.0.take() {
            let _ = t.join();
        }
    }
}

fn code(o: Outcome) -> u8 {
    o as u8
}

impl Capture {
    /// Start streaming `utterance`; each chunk's level goes to `levels`. Returns at once.
    pub fn start(utterance: u32, net: Net, levels: mpsc::Sender<f32>) -> Capture {
        Self::spawn(utterance, net, levels)
    }

    /// Start recording into the pre-roll ring, sending nothing until `begin`. Returns at once.
    pub fn preroll(net: Net, levels: mpsc::Sender<f32>) -> Capture {
        Self::spawn(NO_UTTERANCE, net, levels)
    }

    /// The hold was accepted and `voice_start` sent: stream as `utterance`, the pre-roll first.
    pub fn begin(&self, utterance: u32) {
        self.utterance.store(utterance, Ordering::SeqCst);
    }

    /// Whether `begin` was called (or the capture was started streaming).
    pub fn is_live(&self) -> bool {
        self.utterance.load(Ordering::SeqCst) != NO_UTTERANCE
    }

    /// Discard a pre-roll without waiting for the thread, so a tap is not delayed.
    pub fn abandon(mut self) -> Abandoned {
        self.stop.store(true, Ordering::SeqCst);
        Abandoned(self.thread.take())
    }

    fn spawn(utterance: u32, net: Net, levels: mpsc::Sender<f32>) -> Capture {
        let stop = Arc::new(AtomicBool::new(false));
        let outcome = Arc::new(AtomicU8::new(code(Outcome::Running)));
        let utterance = Arc::new(AtomicU32::new(utterance));
        let (s, o, u) = (stop.clone(), outcome.clone(), utterance.clone());
        let thread = std::thread::Builder::new()
            .name("mic".into())
            .stack_size(8 * 1024)
            .spawn(move || {
                let result = run(&u, &net, &levels, &s);
                // Keep a `Stopped` the app set by asking, unless something ended it first.
                let _ = o.compare_exchange(code(Outcome::Running), code(result), Ordering::SeqCst, Ordering::SeqCst);
            })
            .map_err(|e| log::error!("mic thread did not start: {e}"))
            .ok();
        if thread.is_none() {
            outcome.store(code(Outcome::Failed), Ordering::SeqCst);
        }
        Capture { stop, outcome, utterance, thread }
    }

    /// `Running` while the thread is capturing.
    pub fn outcome(&self) -> Outcome {
        match self.outcome.load(Ordering::SeqCst) {
            x if x == code(Outcome::LimitReached) => Outcome::LimitReached,
            x if x == code(Outcome::Failed) => Outcome::Failed,
            x if x == code(Outcome::Stopped) => Outcome::Stopped,
            _ => Outcome::Running,
        }
    }

    /// Stop capturing and wait for the thread (it finishes the chunk in progress, at most 100 ms).
    pub fn stop(mut self) {
        self.stop.store(true, Ordering::SeqCst);
        if let Some(t) = self.thread.take() {
            let _ = t.join();
        }
    }
}

fn run(utterance: &AtomicU32, net: &Net, levels: &mpsc::Sender<f32>, stop: &AtomicBool) -> Outcome {
    if let Err(e) = display::mic_open() {
        log::warn!("{e:#}");
        return Outcome::Failed;
    }
    let (frames, queued) = mpsc::sync_channel::<Vec<u8>>(UPLINK_QUEUE_CHUNKS);
    let send_failed = Arc::new(AtomicBool::new(false));
    let sender = {
        let (net, failed) = (net.clone(), send_failed.clone());
        std::thread::Builder::new().name("mic-up".into()).stack_size(8 * 1024).spawn(move || {
            // The TLS write runs on this stack, hence the same size as the capture thread.
            let mut max_ms = 0u64;
            for frame in queued {
                if failed.load(Ordering::SeqCst) {
                    continue; // drain without sending: the utterance is being cancelled
                }
                let t = std::time::Instant::now();
                if !net.send_bin(frame) {
                    failed.store(true, Ordering::SeqCst);
                }
                max_ms = max_ms.max(t.elapsed().as_millis() as u64);
            }
            max_ms
        })
    };
    let sender = match sender {
        Ok(h) => h,
        Err(e) => {
            log::error!("uplink thread did not start: {e}");
            display::mic_close();
            return Outcome::Failed;
        }
    };
    let mut chunk = vec![0i16; CHUNK_SAMPLES];
    // The ES7210 clicks as it powers up (measured: chunk levels 493 and 7576, then 308, against a floor of 3 and
    // speech of 100-500), right before the words. Read past it; the pre-roll starts early enough to lose nothing.
    for _ in 0..POWER_ON_CHUNKS {
        if display::mic_read(&mut chunk) != CHUNK_SAMPLES {
            break;
        }
    }
    let mut preroll: VecDeque<Vec<i16>> = VecDeque::with_capacity(PREROLL_CHUNKS);
    let (mut sent_bytes, mut chunks) = (0usize, 0u32);
    // Signal diagnostics for the whole utterance: levels only, never the audio itself.
    let (mut lo, mut hi, mut zeros, mut sq) = (i16::MAX, i16::MIN, 0usize, 0f64);
    let result = loop {
        if stop.load(Ordering::SeqCst) {
            break Outcome::Stopped;
        }
        if display::mic_read(&mut chunk) != CHUNK_SAMPLES {
            log::warn!("microphone read failed after {chunks} chunks");
            break Outcome::Failed;
        }
        // The finger may have lifted while the read blocked: drop that last chunk rather than send it late.
        if stop.load(Ordering::SeqCst) {
            break Outcome::Stopped;
        }
        let id = utterance.load(Ordering::SeqCst);
        if id == NO_UTTERANCE {
            // Not a hold yet: keep the newest chunks, reusing the oldest buffer once the ring is full.
            let mut keep = if preroll.len() == PREROLL_CHUNKS { preroll.pop_front().unwrap() } else { vec![0i16; CHUNK_SAMPLES] };
            keep.copy_from_slice(&chunk);
            preroll.push_back(keep);
            continue;
        }
        if send_failed.load(Ordering::SeqCst) {
            log::warn!("uplink send failed after {chunks} chunks");
            break Outcome::Failed;
        }
        let pending: Vec<Vec<i16>> = preroll.drain(..).collect();
        let mut ended = None;
        for c in pending.iter().map(Vec::as_slice).chain(std::iter::once(chunk.as_slice())) {
            for &v in c {
                lo = lo.min(v);
                hi = hi.max(v);
                zeros += (v == 0) as usize;
                sq += (v as f64) * (v as f64);
            }
            // Never send from this thread: a websocket write can block far longer than the I2S DMA buffer lasts
            // (about 90 ms), and every sample the codec delivers meanwhile is lost.
            match frames.try_send(chunk_to_frame(id, c)) {
                Ok(()) => {}
                Err(mpsc::TrySendError::Full(_)) => {
                    log::warn!("uplink queue full after {chunks} chunks");
                    ended = Some(Outcome::Failed);
                    break;
                }
                Err(mpsc::TrySendError::Disconnected(_)) => {
                    ended = Some(Outcome::Failed);
                    break;
                }
            }
            chunks += 1;
            sent_bytes += CHUNK_SAMPLES * 2;
            if sent_bytes + CHUNK_SAMPLES * 2 > MAX_UTTERANCE_BYTES {
                log::info!("utterance limit reached after {chunks} chunks");
                ended = Some(Outcome::LimitReached);
                break;
            }
        }
        let _ = levels.send(rms_level(&chunk));
        if let Some(o) = ended {
            break o;
        }
    };
    display::mic_close();
    // Let the sender finish what is queued before the app sends voice_end, so the end never overtakes the audio.
    drop(frames);
    let max_send_ms = sender.join().unwrap_or(0);
    let utterance = utterance.load(Ordering::SeqCst);
    if utterance == NO_UTTERANCE {
        log::info!("pre-roll discarded: {result:?}");
        return result;
    }
    let n = chunks as usize * CHUNK_SAMPLES;
    let rms = if n > 0 { (sq / n as f64).sqrt() } else { 0.0 };
    log::info!("capture of utterance {utterance} ended: {result:?}, {chunks} chunks, {sent_bytes} bytes");
    log::info!(
        "capture of utterance {utterance} signal: min={lo} max={hi} rms={rms:.0} zeros={zeros}/{n} max_send_ms={max_send_ms}"
    );
    result
}

