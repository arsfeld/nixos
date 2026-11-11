//! The Centurion voice effect: what it does to a signal, measured on synthetic tones.

use cylon_bot_bridge::voice::backends::{Speech, Tts, VoiceError};
use cylon_bot_bridge::voice::cylon::{Centurion, RING_HZ, STRETCH, centurion};
use futures_util::future::BoxFuture;

const RATE: u32 = 22050;

fn pcm(samples: &[i16]) -> Vec<u8> {
    samples.iter().flat_map(|s| s.to_le_bytes()).collect()
}

fn samples(pcm: &[u8]) -> Vec<i16> {
    pcm.chunks_exact(2).map(|b| i16::from_le_bytes([b[0], b[1]])).collect()
}

fn tone(hz: f32, secs: f32, amp: f32) -> Vec<i16> {
    let n = (RATE as f32 * secs) as usize;
    (0..n).map(|i| (amp * (2.0 * std::f32::consts::PI * hz * i as f32 / RATE as f32).sin()) as i16).collect()
}

/// Power at `hz` (Goertzel), normalised by length.
fn power(x: &[i16], hz: f32) -> f32 {
    let w = 2.0 * std::f32::consts::PI * hz / RATE as f32;
    let c = 2.0 * w.cos();
    let (mut s1, mut s2) = (0f32, 0f32);
    for &v in x {
        let s = v as f32 + c * s1 - s2;
        s2 = s1;
        s1 = s;
    }
    (s1 * s1 + s2 * s2 - c * s1 * s2) / (x.len() as f32 * x.len() as f32)
}

/// The strongest frequency between `lo` and `hi`, in 2 Hz steps.
fn peak_hz(x: &[i16], lo: f32, hi: f32) -> f32 {
    let mut best = (lo, 0f32);
    let mut f = lo;
    while f <= hi {
        let p = power(x, f);
        if p > best.1 {
            best = (f, p);
        }
        f += 2.0;
    }
    best.0
}

#[test]
fn the_output_is_stretched_by_the_stretch_factor() {
    let input = tone(440.0, 1.0, 8000.0);
    let out = samples(&centurion(&pcm(&input), RATE));
    let ratio = out.len() as f32 / input.len() as f32;
    assert!((ratio - STRETCH).abs() < 0.01, "length ratio {ratio}, expected {STRETCH}");
}

#[test]
fn silence_stays_silent() {
    let out = samples(&centurion(&pcm(&vec![0; 22050]), RATE));
    assert!(out.iter().all(|&s| s == 0));
}

#[test]
fn empty_and_odd_input_do_not_panic() {
    assert!(centurion(&[], RATE).is_empty());
    let out = centurion(&[1, 2, 3], RATE);
    assert_eq!(out.len() % 2, 0);
}

#[test]
fn a_full_scale_input_never_wraps() {
    let input = tone(300.0, 0.5, 32767.0);
    let out = samples(&centurion(&pcm(&input), RATE));
    // A wrap shows up as a jump of nearly the whole range between neighbouring samples.
    let worst = out.windows(2).map(|w| (w[1] as i32 - w[0] as i32).abs()).max().unwrap();
    assert!(worst < 30000, "a sample-to-sample jump of {worst} means the signal wrapped");
    assert!(out.iter().any(|&s| s.unsigned_abs() > 10000), "the output is still loud");
}

#[test]
fn the_pitch_is_lowered() {
    let input = tone(440.0, 1.0, 8000.0);
    let out = samples(&centurion(&pcm(&input), RATE));
    // Ring modulation moves the energy to the sidebands of the lowered carrier, so look for the
    // carrier the sidebands sit around: the midpoint of the two strongest peaks.
    let carrier = 440.0 / STRETCH;
    let lower = peak_hz(&out, carrier - RING_HZ - 20.0, carrier - RING_HZ + 20.0);
    let upper = peak_hz(&out, carrier + RING_HZ - 20.0, carrier + RING_HZ + 20.0);
    let mid = (lower + upper) / 2.0;
    assert!((mid - carrier).abs() < 6.0, "the sidebands centre on {mid} Hz, expected {carrier}");
    assert!(mid < 420.0);
}

#[test]
fn ring_modulation_adds_sidebands_around_the_tone() {
    let input = tone(440.0, 1.0, 8000.0);
    let out = samples(&centurion(&pcm(&input), RATE));
    let carrier = 440.0 / STRETCH;
    let side = power(&out, carrier + RING_HZ) + power(&out, carrier - RING_HZ);
    let far = power(&out, carrier + 3.0 * RING_HZ + 17.0);
    assert!(side > 50.0 * far, "sidebands {side} against background {far}");
    // And the plain input has none.
    assert!(power(&input, 440.0 + RING_HZ) * 50.0 < power(&input, 440.0));
}

struct Fixed(Result<Vec<i16>, ()>);

impl Tts for Fixed {
    fn synthesize(&self, _text: String) -> BoxFuture<'static, Result<Speech, VoiceError>> {
        let r = self.0.clone();
        Box::pin(async move {
            match r {
                Ok(s) => Ok(Speech { sample_rate: RATE, pcm: pcm(&s) }),
                Err(()) => Err(VoiceError::Timeout),
            }
        })
    }
}

#[tokio::test]
async fn the_wrapper_applies_the_effect_and_keeps_the_rate() {
    let input = tone(440.0, 0.25, 8000.0);
    let speech = Centurion(Fixed(Ok(input.clone()))).synthesize("By your command".into()).await.unwrap();
    assert_eq!(speech.sample_rate, RATE);
    assert_eq!(speech.pcm, centurion(&pcm(&input), RATE));
}

#[tokio::test]
async fn the_wrapper_passes_errors_through() {
    let r = Centurion(Fixed(Err(()))).synthesize("x".into()).await;
    assert!(matches!(r, Err(VoiceError::Timeout)));
}
