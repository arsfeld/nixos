//! Run the Centurion voice chain over a WAV file, to hear and tune it without deploying:
//!   cargo run --example cylon-wav in.wav out.wav
//! Takes 16-bit mono PCM WAV (what Piper writes) and writes the same format.

use cylon_bot_bridge::voice::cylon::centurion;

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let [_, input, output] = args.as_slice() else {
        eprintln!("usage: cylon-wav in.wav out.wav");
        std::process::exit(2);
    };
    let b = std::fs::read(input).expect("read the input");
    assert!(b.len() >= 12 && &b[0..4] == b"RIFF" && &b[8..12] == b"WAVE", "not a WAV file");
    let (mut rate, mut at) = (0u32, 12usize);
    let pcm = loop {
        assert!(at + 8 <= b.len(), "no data chunk");
        let size = u32::from_le_bytes(b[at + 4..at + 8].try_into().unwrap()) as usize;
        let body = at + 8;
        match &b[at..at + 4] {
            b"fmt " => {
                let channels = u16::from_le_bytes([b[body + 2], b[body + 3]]);
                let bits = u16::from_le_bytes([b[body + 14], b[body + 15]]);
                assert!(channels == 1 && bits == 16, "need 16-bit mono, got {channels} channels at {bits} bits");
                rate = u32::from_le_bytes(b[body + 4..body + 8].try_into().unwrap());
            }
            b"data" => break &b[body..(body + size).min(b.len())],
            _ => {}
        }
        at = body + size + (size & 1);
    };
    let out = centurion(pcm, rate);
    let mut w = Vec::with_capacity(44 + out.len());
    w.extend_from_slice(b"RIFF");
    w.extend_from_slice(&(36 + out.len() as u32).to_le_bytes());
    w.extend_from_slice(b"WAVEfmt ");
    w.extend_from_slice(&16u32.to_le_bytes());
    w.extend_from_slice(&1u16.to_le_bytes());
    w.extend_from_slice(&1u16.to_le_bytes());
    w.extend_from_slice(&rate.to_le_bytes());
    w.extend_from_slice(&(rate * 2).to_le_bytes());
    w.extend_from_slice(&2u16.to_le_bytes());
    w.extend_from_slice(&16u16.to_le_bytes());
    w.extend_from_slice(b"data");
    w.extend_from_slice(&(out.len() as u32).to_le_bytes());
    w.extend_from_slice(&out);
    std::fs::write(output, w).expect("write the output");
}
