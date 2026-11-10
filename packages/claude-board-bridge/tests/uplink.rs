//! The accounting that bounds what the board can queue for the voice task.

use claude_board_bridge::board::Queued;

const AUDIO_BOUND: usize = 256 * 1024;
const CONTROL_BOUND: usize = 64;

#[test]
fn audio_is_accepted_up_to_the_bound_and_dropped_beyond_it() {
    let q = Queued::default();
    let frame = 4000;
    let mut accepted = 0;
    while q.try_audio(frame) {
        accepted += 1;
        assert!(accepted < 1000, "never bounded");
    }
    assert_eq!(accepted, AUDIO_BOUND / frame);
    assert_eq!(q.audio_queued(), accepted * frame);
    // A rejected frame changes nothing, and a small one that still fits is accepted.
    assert!(!q.try_audio(frame));
    assert_eq!(q.audio_queued(), accepted * frame);
    assert!(q.try_audio(AUDIO_BOUND - accepted * frame));
    assert_eq!(q.audio_queued(), AUDIO_BOUND);
    assert!(!q.try_audio(1));
}

#[test]
fn dequeuing_makes_room_again_and_never_underflows() {
    let q = Queued::default();
    assert!(q.try_audio(AUDIO_BOUND));
    assert!(!q.try_audio(1));
    q.audio_done(AUDIO_BOUND);
    assert_eq!(q.audio_queued(), 0);
    assert!(q.try_audio(10));
    // More done than queued must saturate at zero, not wrap.
    q.audio_done(1000);
    assert_eq!(q.audio_queued(), 0);
    assert!(q.try_audio(AUDIO_BOUND));
}

#[test]
fn control_messages_are_bounded_by_count() {
    let q = Queued::default();
    for _ in 0..CONTROL_BOUND {
        assert!(q.try_control());
    }
    assert!(!q.try_control());
    assert_eq!(q.control_queued(), CONTROL_BOUND);
    q.control_done();
    assert!(q.try_control());
    for _ in 0..CONTROL_BOUND + 5 {
        q.control_done();
    }
    assert_eq!(q.control_queued(), 0);
}
