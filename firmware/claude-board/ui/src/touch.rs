//! Turns the touch controller's samples into Slint pointer events, and recognises a swipe right (go back).
//!
//! The controller reports coordinates only while a finger is down; once it is lifted the sample carries
//! nothing usable. A release must therefore happen where the finger last was, or Slint sees it land outside
//! the control that was pressed and never counts the tap.
//!
//! A swipe is a drag mostly sideways and long enough to be deliberate. As soon as it is recognised the pointer
//! is cancelled (`PointerExited`), so the row or button under the finger never sees a click, and the gesture
//! is reported when the finger lifts.

use slint::platform::{PointerEventButton, WindowEvent};
use slint::LogicalPosition;

/// A swipe must travel at least this far sideways...
const SWIPE_MIN_DX: f32 = 70.0;
/// ...and stay mostly horizontal: vertical travel at most this fraction of the sideways travel.
const SWIPE_MAX_SLOPE: f32 = 0.5;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Gesture {
    /// A drag to the right: go back.
    SwipeRight,
}

/// What one sample produced.
#[derive(Debug, Default)]
pub struct Update {
    /// Pointer events to dispatch to the window, in order.
    pub events: Vec<WindowEvent>,
    /// A gesture that just finished.
    pub gesture: Option<Gesture>,
}

#[derive(Debug, Default)]
pub struct TouchTracker {
    /// Where the finger touched down.
    start: Option<LogicalPosition>,
    /// Where the finger is, while it is down.
    down_at: Option<LogicalPosition>,
    /// The drag has been recognised as a swipe and the pointer cancelled; wait for the lift.
    swiping: bool,
}

impl TouchTracker {
    pub fn new() -> Self {
        Self::default()
    }

    /// One sample from the controller: the coordinates (meaningful only when `pressed`) and whether a
    /// finger is down.
    pub fn update(&mut self, x: i16, y: i16, pressed: bool) -> Update {
        let position = LogicalPosition::new(x as f32, y as f32);
        match (self.down_at, pressed) {
            (None, true) => {
                self.start = Some(position);
                self.down_at = Some(position);
                self.swiping = false;
                Update { events: vec![WindowEvent::PointerPressed { position, button: PointerEventButton::Left }], gesture: None }
            }
            (Some(_), true) if self.swiping => {
                self.down_at = Some(position);
                Update::default()
            }
            (Some(last), true) if last != position => {
                self.down_at = Some(position);
                let start = self.start.unwrap_or(position);
                let (dx, dy) = (position.x - start.x, position.y - start.y);
                if dx >= SWIPE_MIN_DX && dy.abs() <= dx * SWIPE_MAX_SLOPE {
                    self.swiping = true;
                    return Update { events: vec![WindowEvent::PointerExited], gesture: None };
                }
                Update { events: vec![WindowEvent::PointerMoved { position }], gesture: None }
            }
            (Some(last), false) => {
                let swiped = self.swiping;
                *self = Self::default();
                if swiped {
                    return Update { events: Vec::new(), gesture: Some(Gesture::SwipeRight) };
                }
                Update {
                    events: vec![WindowEvent::PointerReleased { position: last, button: PointerEventButton::Left }, WindowEvent::PointerExited],
                    gesture: None,
                }
            }
            _ => Update::default(),
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
        let down = t.update(10, 20, true).events;
        assert!(matches!(down.as_slice(), [WindowEvent::PointerPressed { position, .. }] if *position == at(10.0, 20.0)));
        let up = t.update(0, 0, false); // the controller gives no coordinates once the finger is off
        assert!(
            matches!(up.events.as_slice(), [WindowEvent::PointerReleased { position, .. }, WindowEvent::PointerExited] if *position == at(10.0, 20.0)),
            "release must use the last touched position, got {:?}",
            up.events
        );
        assert_eq!(up.gesture, None);
    }

    #[test]
    fn moving_reports_the_new_position_and_release_uses_the_last_one() {
        let mut t = TouchTracker::new();
        t.update(10, 20, true);
        let moved = t.update(30, 40, true).events;
        assert!(matches!(moved.as_slice(), [WindowEvent::PointerMoved { position }] if *position == at(30.0, 40.0)));
        let up = t.update(0, 0, false).events;
        assert!(matches!(up.as_slice(), [WindowEvent::PointerReleased { position, .. }, _] if *position == at(30.0, 40.0)));
    }

    #[test]
    fn holding_still_sends_nothing_new() {
        let mut t = TouchTracker::new();
        t.update(10, 20, true);
        assert!(t.update(10, 20, true).events.is_empty());
    }

    #[test]
    fn no_finger_no_events() {
        let mut t = TouchTracker::new();
        assert!(t.update(0, 0, false).events.is_empty());
        assert!(t.update(5, 5, false).events.is_empty());
    }

    #[test]
    fn a_second_tap_after_the_first_works_the_same() {
        let mut t = TouchTracker::new();
        t.update(1, 2, true);
        t.update(0, 0, false);
        let down = t.update(50, 60, true).events;
        assert!(matches!(down.as_slice(), [WindowEvent::PointerPressed { position, .. }] if *position == at(50.0, 60.0)));
    }

    /// Finger stream for a swipe from (x0, y0) by (dx, dy) in a few steps, then lifted.
    fn drag(t: &mut TouchTracker, x0: i16, y0: i16, dx: i16, dy: i16) -> Vec<Update> {
        let mut out = Vec::new();
        for step in 0..=4 {
            out.push(t.update(x0 + dx * step / 4, y0 + dy * step / 4, true));
        }
        out.push(t.update(0, 0, false));
        out
    }

    #[test]
    fn a_swipe_right_cancels_the_pointer_and_reports_the_gesture_on_release() {
        let mut t = TouchTracker::new();
        let steps = drag(&mut t, 100, 200, 120, 10);
        let events: Vec<&WindowEvent> = steps.iter().flat_map(|u| u.events.iter()).collect();
        // Once it is clearly a swipe the pointer is cancelled (so no row sees a click) and nothing more is sent.
        assert!(events.iter().any(|e| matches!(e, WindowEvent::PointerExited)));
        assert!(!events.iter().any(|e| matches!(e, WindowEvent::PointerReleased { .. })), "a swipe must not end as a click");
        let gestures: Vec<Gesture> = steps.iter().filter_map(|u| u.gesture).collect();
        assert_eq!(gestures, [Gesture::SwipeRight]);
        assert_eq!(steps.last().unwrap().gesture, Some(Gesture::SwipeRight), "reported when the finger lifts");
    }

    #[test]
    fn a_short_sideways_slip_is_still_a_tap() {
        let mut t = TouchTracker::new();
        let steps = drag(&mut t, 100, 200, 30, 4);
        assert!(steps.iter().all(|u| u.gesture.is_none()));
        assert!(steps.iter().flat_map(|u| u.events.iter()).any(|e| matches!(e, WindowEvent::PointerReleased { .. })));
    }

    #[test]
    fn a_vertical_drag_scrolls_and_is_not_a_swipe() {
        let mut t = TouchTracker::new();
        let steps = drag(&mut t, 200, 100, 20, 160);
        assert!(steps.iter().all(|u| u.gesture.is_none()));
    }

    #[test]
    fn a_swipe_left_is_not_back() {
        let mut t = TouchTracker::new();
        let steps = drag(&mut t, 300, 200, -120, 0);
        assert!(steps.iter().all(|u| u.gesture.is_none()));
    }

    #[test]
    fn touches_after_a_swipe_work_normally() {
        let mut t = TouchTracker::new();
        drag(&mut t, 100, 200, 120, 0);
        let down = t.update(50, 60, true).events;
        assert!(matches!(down.as_slice(), [WindowEvent::PointerPressed { position, .. }] if *position == at(50.0, 60.0)));
    }
}
