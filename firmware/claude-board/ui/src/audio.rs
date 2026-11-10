//! The pure side of the microphone path: the level the avatar shows and the frame that goes to the bridge.

use std::collections::VecDeque;

use claude_board_proto::{decode_audio, encode_audio};

/// The loudness of one chunk, 0.0 (silence) to 1.0 (full scale): the RMS of the samples over `i16::MAX`.
pub fn rms_level(samples: &[i16]) -> f32 {
    if samples.is_empty() {
        return 0.0;
    }
    let sum: f64 = samples.iter().map(|&s| (s as f64) * (s as f64)).sum();
    ((sum / samples.len() as f64).sqrt() / i16::MAX as f64).clamp(0.0, 1.0) as f32
}

/// One binary uplink frame: the utterance id and the samples as little-endian PCM16 (see `encode_audio`).
pub fn chunk_to_frame(utterance: u32, samples: &[i16]) -> Vec<u8> {
    let mut pcm = Vec::with_capacity(samples.len() * 2);
    for s in samples {
        pcm.extend_from_slice(&s.to_le_bytes());
    }
    encode_audio(utterance, &pcm)
}

/// The `cancel` message for an utterance, for the app to send when the capture dies on its own (the controller only
/// cancels speech).
pub fn cancel_json(utterance: u32) -> String {
    serde_json::to_string(&claude_board_proto::ClientMsg::Cancel { utterance }).expect("a ClientMsg serialises")
}

/// The speech messages the app must see to drive the player (the controller handles the rest).
#[derive(Debug, PartialEq, Eq)]
pub enum SpeechEvent {
    Start { utterance: u32, rate: u32 },
    End,
}

/// Recognise `speak_start` / `speak_end` in a text frame; None for everything else.
pub fn speech_event(json: &str) -> Option<SpeechEvent> {
    match serde_json::from_str::<claude_board_proto::BoardMsg>(json) {
        Ok(claude_board_proto::BoardMsg::SpeakStart { utterance, sample_rate }) => Some(SpeechEvent::Start { utterance, rate: sample_rate }),
        Ok(claude_board_proto::BoardMsg::SpeakEnd { .. }) => Some(SpeechEvent::End),
        _ => None,
    }
}

/// The most PCM bytes `Playback` holds at once: 1 MiB, about 23 s at 22 050 Hz. The bridge sends a reply as fast as
/// it is synthesised, faster than it plays, and the queue lives in PSRAM, so it is sized for a long reply. Past the
/// cap the NEWEST audio is dropped and counted in `dropped_bytes`: the queued speech stays intact and in order, a frame
/// that does not fit whole keeps its leading part (whole samples) and loses the rest, and a later, smaller frame can
/// fit again once the player has drained some. So a reply longer than about 23 s that arrives faster than it plays can
/// skip in the middle, not only lose its end.
pub const PLAYBACK_CAP: usize = 1024 * 1024;
/// The most bytes `next_chunk` hands out: 4 096 bytes, about 93 ms at 22 050 Hz, so a stop is noticed quickly.
pub const PLAYBACK_CHUNK: usize = 4096;

/// What is playing, as a pure state machine: the app's player thread pulls chunks from it and the UI loop feeds and
/// stops it (under one mutex, see `app/src/speaker.rs`).
#[derive(Debug, Default)]
pub struct Playback {
    utterance: u32,
    rate: u32,
    begun: bool,
    ended: bool,
    queue: VecDeque<u8>,
    /// An odd trailing byte of the last frame, waiting for the first byte of the next (samples are two bytes).
    carry: Option<u8>,
    dropped: usize,
}

impl Playback {
    pub fn new() -> Playback {
        Playback::default()
    }

    /// Start an utterance at `rate`, replacing whatever was playing.
    pub fn begin(&mut self, utterance: u32, rate: u32) {
        *self = Playback { utterance, rate, begun: true, ..Playback::default() };
    }

    /// One binary downlink frame. Ignored when idle, for another utterance, shorter than the header, or after `end`.
    pub fn push(&mut self, frame: &[u8]) {
        if !self.begun || self.ended {
            return;
        }
        let Some((utterance, pcm)) = decode_audio(frame) else { return };
        if utterance != self.utterance {
            return;
        }
        let mut pcm = pcm;
        let mut room = PLAYBACK_CAP.saturating_sub(self.queue.len());
        // Finish a sample left half-written by the previous frame.
        if let (Some(lo), Some((&hi, rest))) = (self.carry, pcm.split_first()) {
            if room >= 2 {
                self.queue.extend([lo, hi]);
                room -= 2;
            } else {
                self.dropped += 2;
            }
            self.carry = None;
            pcm = rest;
        }
        let even = pcm.len() & !1;
        let take = even.min(room & !1);
        self.queue.extend(&pcm[..take]);
        self.dropped += even - take;
        if pcm.len() > even {
            self.carry = Some(pcm[even]);
        }
    }

    /// No more audio is coming; what is queued still plays out.
    pub fn end(&mut self) {
        self.ended = true;
        self.carry = None;
    }

    /// Discard everything and go idle at once.
    pub fn stop(&mut self) {
        *self = Playback { dropped: self.dropped, ..Playback::default() };
    }

    /// The next piece to play: whole samples, at most `PLAYBACK_CHUNK` bytes. None when nothing is queued.
    pub fn next_chunk(&mut self) -> Option<Vec<u8>> {
        let n = self.queue.len().min(PLAYBACK_CHUNK) & !1;
        (n > 0).then(|| self.queue.drain(..n).collect())
    }

    /// The sample rate of what is playing or draining; None when idle.
    pub fn rate(&self) -> Option<u32> {
        (!self.is_idle()).then_some(self.rate)
    }

    /// Nothing to play and nothing more coming: never begun, stopped, or ended and drained.
    pub fn is_idle(&self) -> bool {
        !self.begun || (self.ended && self.queue.is_empty())
    }

    /// Bytes refused or lost to the cap since this value was created (kept across `stop`, reset by `begin`).
    pub fn dropped_bytes(&self) -> usize {
        self.dropped
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use claude_board_proto::decode_audio;

    #[test]
    fn silence_is_zero_and_empty_is_zero() {
        assert_eq!(rms_level(&[0; 1600]), 0.0);
        assert_eq!(rms_level(&[]), 0.0);
    }

    #[test]
    fn a_full_scale_square_wave_is_about_one() {
        let wave: Vec<i16> = (0..1600).map(|i| if i % 2 == 0 { i16::MAX } else { i16::MIN }).collect();
        let level = rms_level(&wave);
        assert!(level > 0.99 && level <= 1.0, "{level}");
    }

    #[test]
    fn a_quieter_signal_reads_lower_and_stays_in_range() {
        let quiet = rms_level(&[1000, -1000, 1000, -1000]);
        let loud = rms_level(&[20000, -20000, 20000, -20000]);
        assert!(0.0 < quiet && quiet < loud && loud <= 1.0);
        assert!((0.0..=1.0).contains(&rms_level(&[i16::MIN; 8])));
    }

    #[test]
    fn cancel_json_is_a_cancel_message() {
        assert_eq!(cancel_json(3), r#"{"t":"cancel","utterance":3}"#);
    }

    #[test]
    fn a_frame_carries_the_utterance_and_little_endian_samples() {
        let frame = chunk_to_frame(7, &[1, -2, 0x1234]);
        let (utterance, pcm) = decode_audio(&frame).expect("decodes");
        assert_eq!(utterance, 7);
        assert_eq!(pcm, [1, 0, 0xFE, 0xFF, 0x34, 0x12]);
        assert_eq!(frame.len(), claude_board_proto::AUDIO_HEADER_LEN + 6);
    }

    fn frame(utterance: u32, pcm: &[u8]) -> Vec<u8> {
        claude_board_proto::encode_audio(utterance, pcm)
    }

    #[test]
    fn a_new_playback_is_idle() {
        let p = Playback::new();
        assert!(p.is_idle());
        assert_eq!(p.rate(), None);
    }

    #[test]
    fn chunks_come_out_in_order() {
        let mut p = Playback::new();
        p.begin(1, 22_050);
        assert_eq!(p.rate(), Some(22_050));
        p.push(&frame(1, &[1, 0, 2, 0]));
        p.push(&frame(1, &[3, 0]));
        let mut all = Vec::new();
        while let Some(c) = p.next_chunk() {
            all.extend(c);
        }
        assert_eq!(all, [1, 0, 2, 0, 3, 0]);
        assert_eq!(p.next_chunk(), None);
        assert!(!p.is_idle(), "not ended yet: more may come");
    }

    #[test]
    fn a_long_frame_is_cut_into_bounded_chunks() {
        let mut p = Playback::new();
        p.begin(1, 22_050);
        p.push(&frame(1, &vec![7; 10_000]));
        let mut sizes = Vec::new();
        while let Some(c) = p.next_chunk() {
            sizes.push(c.len());
        }
        assert_eq!(sizes, [4096, 4096, 1808]);
    }

    #[test]
    fn audio_for_another_utterance_is_ignored() {
        let mut p = Playback::new();
        p.begin(1, 22_050);
        p.push(&frame(2, &[1, 0]));
        assert_eq!(p.next_chunk(), None);
    }

    #[test]
    fn audio_while_idle_is_ignored() {
        let mut p = Playback::new();
        p.push(&frame(0, &[1, 0]));
        assert_eq!(p.next_chunk(), None);
        p.begin(1, 22_050);
        p.end();
        p.push(&frame(1, &[1, 0]));
        assert_eq!(p.next_chunk(), None);
    }

    #[test]
    fn a_frame_shorter_than_the_header_is_ignored() {
        let mut p = Playback::new();
        p.begin(1, 22_050);
        p.push(&[1, 0]);
        p.push(&[]);
        p.push(&frame(1, &[5, 0]));
        assert_eq!(p.next_chunk(), Some(vec![5, 0]));
    }

    #[test]
    fn stop_discards_queued_audio_and_goes_idle() {
        let mut p = Playback::new();
        p.begin(1, 22_050);
        p.push(&frame(1, &[1, 0, 2, 0]));
        p.stop();
        assert!(p.is_idle());
        assert_eq!(p.rate(), None);
        assert_eq!(p.next_chunk(), None);
        p.push(&frame(1, &[1, 0]));
        assert_eq!(p.next_chunk(), None, "stopped: late frames are ignored");
    }

    #[test]
    fn end_lets_queued_audio_drain_before_idle() {
        let mut p = Playback::new();
        p.begin(1, 22_050);
        p.push(&frame(1, &[1, 0, 2, 0]));
        p.end();
        assert!(!p.is_idle());
        assert_eq!(p.rate(), Some(22_050));
        assert_eq!(p.next_chunk(), Some(vec![1, 0, 2, 0]));
        assert!(p.is_idle());
    }

    #[test]
    fn begin_for_a_new_utterance_replaces_an_old_one() {
        let mut p = Playback::new();
        p.begin(1, 22_050);
        p.push(&frame(1, &[1, 0]));
        p.begin(2, 16_000);
        assert_eq!(p.rate(), Some(16_000));
        p.push(&frame(1, &[9, 0]));
        p.push(&frame(2, &[3, 0]));
        assert_eq!(p.next_chunk(), Some(vec![3, 0]));
    }

    #[test]
    fn every_chunk_is_sample_aligned_even_when_frames_split_samples() {
        let mut p = Playback::new();
        p.begin(1, 22_050);
        p.push(&frame(1, &[1, 0, 2])); // odd: 2 is half a sample
        p.push(&frame(1, &[0, 3, 0, 4]));
        p.push(&frame(1, &[0]));
        let mut all = Vec::new();
        while let Some(c) = p.next_chunk() {
            assert_eq!(c.len() % 2, 0);
            all.extend(c);
        }
        assert_eq!(all, [1, 0, 2, 0, 3, 0, 4, 0]);
    }

    #[test]
    fn the_queue_is_capped_and_the_newest_audio_is_dropped_and_counted() {
        let mut p = Playback::new();
        p.begin(1, 22_050);
        let big = vec![1u8; 32 * 1024];
        for _ in 0..40 {
            p.push(&frame(1, &big));
        }
        let mut total = 0;
        while let Some(c) = p.next_chunk() {
            total += c.len();
        }
        assert_eq!(total, PLAYBACK_CAP);
        assert_eq!(p.dropped_bytes(), 40 * 32 * 1024 - PLAYBACK_CAP);
    }
}

/// Speaker volume, 0 to 100 on the codec's scale (logarithmic, about 0.5 dB a step): the board starts here and a
/// swipe on home moves it by `VOLUME_STEP`, within `VOLUME_MIN..=VOLUME_MAX`.
pub const VOLUME_DEFAULT: u8 = 80;
pub const VOLUME_MIN: u8 = 10;
pub const VOLUME_MAX: u8 = 100;
pub const VOLUME_STEP: u8 = 10;

/// The volume one swipe up (`louder`) or down from `v`; a stored value out of range is brought back into it.
pub fn volume_step(v: u8, louder: bool) -> u8 {
    let v = v.clamp(VOLUME_MIN, VOLUME_MAX);
    if louder { v.saturating_add(VOLUME_STEP).min(VOLUME_MAX) } else { v.saturating_sub(VOLUME_STEP).max(VOLUME_MIN) }
}

#[cfg(test)]
mod volume_tests {
    use super::*;

    #[test]
    fn volume_steps_stop_at_the_ends() {
        assert_eq!(volume_step(VOLUME_DEFAULT, true), 90);
        assert_eq!(volume_step(95, true), VOLUME_MAX);
        assert_eq!(volume_step(VOLUME_MAX, true), VOLUME_MAX);
        assert_eq!(volume_step(VOLUME_MIN, false), VOLUME_MIN);
        assert_eq!(volume_step(15, false), VOLUME_MIN);
        assert_eq!(volume_step(255, false), 90, "an out-of-range stored value is clamped first");
    }
}
