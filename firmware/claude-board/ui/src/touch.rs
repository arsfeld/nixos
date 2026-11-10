//! Turns the touch controller's samples into Slint pointer events.
//!
//! The controller reports coordinates only while a finger is down; once it is lifted the sample carries
//! nothing usable. A release must therefore happen where the finger last was, or Slint sees it land outside
//! the control that was pressed and never counts the tap.

use slint::platform::{PointerEventButton, WindowEvent};
use slint::LogicalPosition;

#[derive(Debug, Default)]
pub struct TouchTracker {
    /// Where the finger is, while it is down.
    down_at: Option<LogicalPosition>,
}

impl TouchTracker {
    pub fn new() -> Self {
        Self::default()
    }

    /// One sample from the controller: the coordinates (meaningful only when `pressed`) and whether a
    /// finger is down. Returns the events to dispatch, in order.
    pub fn update(&mut self, x: i16, y: i16, pressed: bool) -> Vec<WindowEvent> {
        let position = LogicalPosition::new(x as f32, y as f32);
        match (self.down_at, pressed) {
            (None, true) => {
                self.down_at = Some(position);
                vec![WindowEvent::PointerPressed { position, button: PointerEventButton::Left }]
            }
            (Some(last), true) if last != position => {
                self.down_at = Some(position);
                vec![WindowEvent::PointerMoved { position }]
            }
            (Some(last), false) => {
                self.down_at = None;
                vec![WindowEvent::PointerReleased { position: last, button: PointerEventButton::Left }, WindowEvent::PointerExited]
            }
            _ => Vec::new(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use slint::platform::WindowEvent;
    use slint::LogicalPosition;

    fn at(x: f32, y: f32) -> LogicalPosition {
        LogicalPosition::new(x, y)
    }

    #[test]
    fn a_tap_is_press_then_release_at_the_same_place() {
        let mut t = TouchTracker::new();
        let down = t.update(10, 20, true);
        assert!(matches!(down.as_slice(), [WindowEvent::PointerPressed { position, .. }] if *position == at(10.0, 20.0)));
        let up = t.update(0, 0, false); // the controller gives no coordinates once the finger is off
        assert!(
            matches!(up.as_slice(), [WindowEvent::PointerReleased { position, .. }, WindowEvent::PointerExited] if *position == at(10.0, 20.0)),
            "release must use the last touched position, got {up:?}"
        );
    }

    #[test]
    fn moving_reports_the_new_position_and_release_uses_the_last_one() {
        let mut t = TouchTracker::new();
        t.update(10, 20, true);
        let moved = t.update(30, 40, true);
        assert!(matches!(moved.as_slice(), [WindowEvent::PointerMoved { position }] if *position == at(30.0, 40.0)));
        let up = t.update(0, 0, false);
        assert!(matches!(up.as_slice(), [WindowEvent::PointerReleased { position, .. }, _] if *position == at(30.0, 40.0)));
    }

    #[test]
    fn holding_still_sends_nothing_new() {
        let mut t = TouchTracker::new();
        t.update(10, 20, true);
        assert!(t.update(10, 20, true).is_empty());
    }

    #[test]
    fn no_finger_no_events() {
        let mut t = TouchTracker::new();
        assert!(t.update(0, 0, false).is_empty());
        assert!(t.update(5, 5, false).is_empty());
    }

    #[test]
    fn a_second_tap_after_the_first_works_the_same() {
        let mut t = TouchTracker::new();
        t.update(1, 2, true);
        t.update(0, 0, false);
        let down = t.update(50, 60, true);
        assert!(matches!(down.as_slice(), [WindowEvent::PointerPressed { position, .. }] if *position == at(50.0, 60.0)));
    }
}
