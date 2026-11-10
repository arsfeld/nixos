//! Spoken replies: the bridge's audio queue and the thread that plays it.
//!
//! Structure: one `Mutex<Playback>` shared by the UI loop (which feeds it on SpeakStart / Audio / SpeakEnd and stops
//! it) and one player thread (which takes chunks out and writes them to the speaker). The thread owns the speaker
//! stream: it opens it at the rate of whatever `Playback` is playing and closes it when `Playback` goes idle or the
//! rate changes, so `stop()` is just "empty the queue": the thread notices at its next iteration, at most one chunk
//! (about 93 ms) later, and closes the stream. The UI loop therefore never blocks on audio, except `stop_and_wait`,
//! used before the microphone opens.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use claude_board_ui::audio::Playback;

use crate::display;

struct Shared {
    playback: Mutex<Playback>,
    /// The thread has the speaker stream open.
    open: AtomicBool,
}

#[derive(Clone)]
pub struct Player(Arc<Shared>);

impl Player {
    pub fn start() -> anyhow::Result<Player> {
        let shared = Arc::new(Shared { playback: Mutex::new(Playback::new()), open: AtomicBool::new(false) });
        let thread_shared = shared.clone();
        std::thread::Builder::new().name("speaker".into()).stack_size(6 * 1024).spawn(move || run(thread_shared))?;
        Ok(Player(shared))
    }

    pub fn begin(&self, utterance: u32, rate: u32) {
        self.0.playback.lock().unwrap().begin(utterance, rate);
    }

    pub fn push(&self, frame: &[u8]) {
        self.0.playback.lock().unwrap().push(frame);
    }

    pub fn end(&self) {
        self.0.playback.lock().unwrap().end();
    }

    /// Discard the queue; the stream closes within one chunk.
    pub fn stop(&self) {
        self.0.playback.lock().unwrap().stop();
    }

    /// Audio is queued or playing.
    pub fn is_playing(&self) -> bool {
        !self.0.playback.lock().unwrap().is_idle()
    }

    /// Stop and wait (up to 1 s) for the stream to close, so the microphone can take the clock.
    pub fn stop_and_wait(&self) {
        self.stop();
        let until = Instant::now() + Duration::from_secs(1);
        while self.0.open.load(Ordering::SeqCst) && Instant::now() < until {
            std::thread::sleep(Duration::from_millis(10));
        }
    }
}

fn run(shared: Arc<Shared>) {
    let mut open_rate: Option<u32> = None;
    loop {
        // One lock: the chunk and the rate it belongs to.
        let (chunk, rate) = {
            let mut p = shared.playback.lock().unwrap();
            let rate = p.rate(); // before the chunk: the last chunk empties the queue and makes it idle
            (p.next_chunk(), rate)
        };
        // The stream must match what is playing: close when idle or when the rate changed.
        if open_rate.is_some() && open_rate != rate {
            display::speaker_end();
            shared.open.store(false, Ordering::SeqCst);
            open_rate = None;
        }
        match (chunk, rate) {
            (Some(mut pcm), Some(rate)) => {
                if open_rate.is_none() {
                    match display::speaker_begin(rate) {
                        Ok(()) => {
                            shared.open.store(true, Ordering::SeqCst);
                            open_rate = Some(rate);
                        }
                        Err(e) => {
                            // Nothing can play (microphone open, or no speaker): drop this utterance.
                            log::warn!("speech dropped: {e:#}");
                            shared.playback.lock().unwrap().stop();
                            continue;
                        }
                    }
                }
                if !display::speaker_write(&mut pcm) {
                    log::warn!("speaker write failed: stopping speech");
                    shared.playback.lock().unwrap().stop();
                }
            }
            // Nothing queued yet (the network is behind, or the reply is over): wait a moment.
            _ => std::thread::sleep(Duration::from_millis(15)),
        }
    }
}
