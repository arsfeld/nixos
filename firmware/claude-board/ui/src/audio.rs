//! The pure side of the microphone path: the level the avatar shows and the frame that goes to the bridge.

use claude_board_proto::encode_audio;

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
}
