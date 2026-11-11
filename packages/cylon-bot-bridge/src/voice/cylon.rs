//! The creature's Centurion voice: an effect chain over Piper's 16-bit mono PCM, applied per sentence.
//!
//! 1. Lower and slower: resampled `STRETCH` times longer at the same rate, which drops the pitch by
//!    about 2.4 semitones and slows the speech. Done here rather than by announcing a lower rate in
//!    `speak_start`, so the board's I2S only ever sees the rate Piper produces.
//! 2. Ring modulation at `RING_HZ`, mixed `RING_MIX` against the dry signal: the metallic buzz.
//! 3. A short flange (`FLANGE_*`): a delayed copy swept slowly, the hollow "inside a helmet" tone.
//! 4. A limiter: if the sum would pass `PEAK`, the whole sentence is scaled down, so it never wraps.
//!
//! Every sentence starts the modulators at phase zero; at sentence boundaries that is inaudible.
//! Tune the constants with `cargo run --example cylon-wav in.wav out.wav`.

use super::backends::{Speech, Tts, VoiceError};
use futures_util::future::BoxFuture;
use std::f32::consts::PI;

pub const STRETCH: f32 = 1.15;
pub const RING_HZ: f32 = 70.0;
pub const RING_MIX: f32 = 0.6;
pub const FLANGE_DELAY_MS: f32 = 6.0;
pub const FLANGE_DEPTH_MS: f32 = 2.0;
pub const FLANGE_HZ: f32 = 0.5;
pub const FLANGE_GAIN: f32 = 0.5;
pub const PEAK: f32 = 30000.0;

/// Linear interpolation into `x` at a fractional index; zero outside it.
fn at(x: &[f32], pos: f32) -> f32 {
    if pos < 0.0 {
        return 0.0;
    }
    let i = pos as usize;
    let f = pos - i as f32;
    let a = x.get(i).copied().unwrap_or(0.0);
    let b = x.get(i + 1).copied().unwrap_or(0.0);
    a + (b - a) * f
}

/// Apply the Centurion chain to little-endian 16-bit mono PCM at `rate` Hz. A trailing odd byte is
/// dropped.
pub fn centurion(pcm: &[u8], rate: u32) -> Vec<u8> {
    let x: Vec<f32> = pcm.chunks_exact(2).map(|b| i16::from_le_bytes([b[0], b[1]]) as f32).collect();
    if x.is_empty() {
        return Vec::new();
    }
    let rate = rate as f32;
    let n = (x.len() as f32 * STRETCH).round() as usize;

    // 1 and 2: stretch, then ring-modulate.
    let ringed: Vec<f32> = (0..n)
        .map(|j| {
            let t = j as f32 / rate;
            let carrier = (2.0 * PI * RING_HZ * t).sin();
            at(&x, j as f32 / STRETCH) * ((1.0 - RING_MIX) + RING_MIX * carrier)
        })
        .collect();

    // 3: flange.
    let mut y: Vec<f32> = (0..n)
        .map(|j| {
            let t = j as f32 / rate;
            let delay_ms = FLANGE_DELAY_MS + FLANGE_DEPTH_MS * (2.0 * PI * FLANGE_HZ * t).sin();
            ringed[j] + FLANGE_GAIN * at(&ringed, j as f32 - delay_ms * rate / 1000.0)
        })
        .collect();

    // 4: limit.
    let peak = y.iter().fold(0f32, |m, v| m.max(v.abs()));
    if peak > PEAK {
        let g = PEAK / peak;
        y.iter_mut().for_each(|v| *v *= g);
    }
    y.iter().flat_map(|v| (v.round().clamp(-32768.0, 32767.0) as i16).to_le_bytes()).collect()
}

/// A `Tts` whose speech comes out in the Centurion voice.
pub struct Centurion<T>(pub T);

impl<T: Tts> Tts for Centurion<T> {
    fn synthesize(&self, text: String) -> BoxFuture<'static, Result<Speech, VoiceError>> {
        let inner = self.0.synthesize(text);
        Box::pin(async move {
            let speech = inner.await?;
            let pcm = centurion(&speech.pcm, speech.sample_rate);
            Ok(Speech { sample_rate: speech.sample_rate, pcm })
        })
    }
}
