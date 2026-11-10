//! Press-to-talk capture: a thread that reads the microphone in 100 ms chunks and streams each to the bridge.
//!
//! Memory: one 1600-sample chunk buffer (3.2 KB) reused for the whole utterance, and one frame `Vec` per chunk
//! that is freed after the send; nothing grows. Capture and the chime share an I2S clock, handled inside the C
//! component (`bd_mic_open` waits for a chime in progress, and the chime skips itself while the mic is open).
//!
//! The thread ends on its own after `MAX_UTTERANCE_BYTES` or when the microphone or a send fails; the app
//! learns about it from `Capture::outcome` (and the levels channel closing). The app, not the thread, tells the
//! controller and the bridge, so a failure is a cancel and the limit is a release.

use std::sync::atomic::{AtomicBool, AtomicU8, Ordering};
use std::sync::{mpsc, Arc};
use std::thread::JoinHandle;

use claude_board_proto::MAX_UTTERANCE_BYTES;
use claude_board_ui::audio::{chunk_to_frame, rms_level};
use claude_board_ui::controller::Outbox;

use crate::display;
use crate::net::Net;

/// 100 ms at the uplink rate.
const CHUNK_SAMPLES: usize = 1600;

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
    thread: Option<JoinHandle<()>>,
}

fn code(o: Outcome) -> u8 {
    o as u8
}

impl Capture {
    /// Start streaming `utterance`; each chunk's level goes to `levels`. Returns at once.
    pub fn start(utterance: u32, net: Net, levels: mpsc::Sender<f32>) -> Capture {
        let stop = Arc::new(AtomicBool::new(false));
        let outcome = Arc::new(AtomicU8::new(code(Outcome::Running)));
        let (s, o) = (stop.clone(), outcome.clone());
        let thread = std::thread::Builder::new()
            .name("mic".into())
            .stack_size(8 * 1024)
            .spawn(move || {
                let result = run(utterance, &net, &levels, &s);
                // Keep a `Stopped` the app set by asking, unless something ended it first.
                let _ = o.compare_exchange(code(Outcome::Running), code(result), Ordering::SeqCst, Ordering::SeqCst);
            })
            .map_err(|e| log::error!("mic thread did not start: {e}"))
            .ok();
        if thread.is_none() {
            outcome.store(code(Outcome::Failed), Ordering::SeqCst);
        }
        Capture { stop, outcome, thread }
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

fn run(utterance: u32, net: &Net, levels: &mpsc::Sender<f32>, stop: &AtomicBool) -> Outcome {
    if let Err(e) = display::mic_open() {
        log::warn!("{e:#}");
        return Outcome::Failed;
    }
    let mut chunk = vec![0i16; CHUNK_SAMPLES];
    let (mut sent_bytes, mut chunks) = (0usize, 0u32);
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
        let _ = levels.send(rms_level(&chunk));
        if !net.send_bin(chunk_to_frame(utterance, &chunk)) {
            log::warn!("uplink send failed after {chunks} chunks");
            break Outcome::Failed;
        }
        chunks += 1;
        sent_bytes += CHUNK_SAMPLES * 2;
        if sent_bytes + CHUNK_SAMPLES * 2 > MAX_UTTERANCE_BYTES {
            log::info!("utterance limit reached after {chunks} chunks");
            break Outcome::LimitReached;
        }
    };
    display::mic_close();
    log::info!("capture of utterance {utterance} ended: {result:?}, {chunks} chunks, {sent_bytes} bytes");
    result
}
