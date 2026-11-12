//! Turns the touch controller's samples into Slint pointer events, and recognises a swipe right (go back) and,
//! where the app allows it (`set_vertical_swipes`, the home page, which scrolls nothing), swipes up and down
//! (volume).
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

/// A swipe down that starts above this y (the top of the round screen) is an edge swipe, not "quieter".
pub const EDGE_BAND_PX: f32 = 60.0;

/// A finger held this long, nearly still, is a hold (press to talk).
pub const HOLD_MS: u64 = 450;
/// "Nearly still": the finger stays within this many pixels of where it landed.
pub const HOLD_SLOP_PX: i16 = 20;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Gesture {
    /// A drag to the right: go back.
    SwipeRight,
    /// A drag up or down, only while vertical swipes are on: louder, quieter.
    SwipeUp,
    SwipeDown,
    /// Like `SwipeDown`, but it started in the top `EDGE_BAND_PX`: opens the command menu.
    EdgeDown,
    /// The finger has been down, nearly still, for `HOLD_MS`; carries where it is. Nothing is cancelled yet: the
    /// pointer stays down, and the lift is an ordinary click unless the app accepts the hold. The app's call
    /// order is `HoldStart(x, y)` -> `controller.hold_started(x, y)` -> only if that returned true,
    /// `tracker.accept_hold()` and dispatch the events it returns. A hold the controller refuses (off the
    /// avatar, or on a page with controls) therefore behaves as a slow tap.
    HoldStart(i16, i16),
    /// The finger of an *accepted* hold has lifted (stop the microphone: `controller.hold_ended()`).
    HoldEnd,
}

/// What one sample produced.
#[derive(Debug, Default)]
pub struct Update {
    /// Pointer events to dispatch to the window, in order.
    pub events: Vec<WindowEvent>,
    /// A gesture that just finished (or, for `HoldStart`, just began).
    pub gesture: Option<Gesture>,
}

#[derive(Debug, Default)]
pub struct TouchTracker {
    /// Where the finger touched down.
    start: Option<LogicalPosition>,
    /// Where the finger is, while it is down.
    down_at: Option<LogicalPosition>,
    /// The drag has been recognised as a swipe and the pointer cancelled; wait for the lift.
    swiping: Option<Gesture>,
    /// Up and down drags are swipes (off by default: elsewhere they scroll).
    vertical: bool,
    /// When the finger landed, and whether it could still turn into a hold (it has not strayed).
    down_ms: u64,
    hold_possible: bool,
    /// The hold was accepted (`accept_hold`) and the pointer cancelled; the lift ends it.
    holding: bool,
    /// `HoldStart` has been emitted for this touch (accepted or not).
    hold_fired: bool,
}

impl TouchTracker {
    pub fn new() -> Self {
        Self::default()
    }

    /// Whether up and down drags count as swipes. Takes effect from the next touch-down.
    pub fn set_vertical_swipes(&mut self, on: bool) {
        self.vertical = on;
    }

    /// `update_at` for callers with no clock: time never advances, so nothing is ever a hold.
    pub fn update(&mut self, x: i16, y: i16, pressed: bool) -> Update {
        self.update_at(x, y, pressed, 0)
    }

    /// The app calls this when `controller.hold_started` accepted a `HoldStart`: it returns the events that cancel
    /// the pointer (so no click follows) and makes the lift emit `Gesture::HoldEnd`. Empty when no hold is
    /// pending.
    pub fn accept_hold(&mut self) -> Vec<WindowEvent> {
        if self.down_at.is_none() || !self.hold_fired || self.holding {
            return Vec::new();
        }
        self.holding = true;
        vec![WindowEvent::PointerExited]
    }

    /// One sample from the controller: the coordinates (meaningful only when `pressed`), whether a finger is
    /// down, and the monotonic time in milliseconds.
    pub fn update_at(&mut self, x: i16, y: i16, pressed: bool, now_ms: u64) -> Update {
        let position = LogicalPosition::new(x as f32, y as f32);
        match (self.down_at, pressed) {
            (None, true) => {
                self.start = Some(position);
                self.down_at = Some(position);
                self.swiping = None;
                self.holding = false;
                self.hold_fired = false;
                self.hold_possible = true;
                self.down_ms = now_ms;
                Update { events: vec![WindowEvent::PointerPressed { position, button: PointerEventButton::Left }], gesture: None }
            }
            (Some(_), true) if self.swiping.is_some() || self.holding => {
                self.down_at = Some(position);
                Update::default()
            }
            (Some(last), true) => {
                let start = self.start.unwrap_or(position);
                let (dx, dy) = (position.x - start.x, position.y - start.y);
                if dx.abs() > HOLD_SLOP_PX as f32 || dy.abs() > HOLD_SLOP_PX as f32 {
                    self.hold_possible = false;
                }
                if self.hold_possible && now_ms.saturating_sub(self.down_ms) >= HOLD_MS {
                    self.hold_fired = true;
                    self.hold_possible = false;
                    self.down_at = Some(position);
                    return Update { events: Vec::new(), gesture: Some(Gesture::HoldStart(x, y)) };
                }
                if last == position {
                    return Update::default();
                }
                self.down_at = Some(position);
                let swipe = if dx >= SWIPE_MIN_DX && dy.abs() <= dx * SWIPE_MAX_SLOPE {
                    Some(Gesture::SwipeRight)
                } else if self.vertical && dy.abs() >= SWIPE_MIN_DX && dx.abs() <= dy.abs() * SWIPE_MAX_SLOPE {
                    Some(if dy < 0.0 {
                        Gesture::SwipeUp
                    } else if start.y < EDGE_BAND_PX {
                        Gesture::EdgeDown
                    } else {
                        Gesture::SwipeDown
                    })
                } else {
                    None
                };
                if swipe.is_some() {
                    self.swiping = swipe;
                    return Update { events: vec![WindowEvent::PointerExited], gesture: None };
                }
                Update { events: vec![WindowEvent::PointerMoved { position }], gesture: None }
            }
            (Some(last), false) => {
                let (swiped, held, vertical) = (self.swiping, self.holding, self.vertical);
                *self = Self { vertical, ..Self::default() };
                if held {
                    return Update { events: Vec::new(), gesture: Some(Gesture::HoldEnd) };
                }
                if swiped.is_some() {
                    return Update { events: Vec::new(), gesture: swiped };
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

/// The touch that wakes a dark panel only wakes it: its samples, up to and including its release, never reach the
/// tracker, so a tap meant to light the screen cannot answer the question that lit it.
#[derive(Debug, Default)]
pub struct WakeGate {
    swallowing: bool,
}

impl WakeGate {
    pub fn new() -> Self {
        WakeGate::default()
    }

    /// Whether this touch sample may go on to the tracker. `dark` is the panel's state as the sample is read.
    pub fn pass(&mut self, dark: bool, pressed: bool) -> bool {
        if self.swallowing {
            if !pressed {
                self.swallowing = false;
            }
            return false;
        }
        if dark && pressed {
            self.swallowing = true;
            return false;
        }
        true
    }
}

#[cfg(test)]
mod tests {
    #[test]
    fn the_waking_touch_is_dropped_until_lift() {
        let mut g = WakeGate::new();
        assert!(!g.pass(true, true)); // first touch on a dark panel
        assert!(!g.pass(false, true)); // panel now lit, same finger still down
        assert!(!g.pass(false, false)); // its lift
        assert!(g.pass(false, true)); // next touch lands
        assert!(g.pass(false, false));
    }

    #[test]
    fn touches_while_lit_pass() {
        let mut g = WakeGate::new();
        assert!(g.pass(false, true));
        assert!(g.pass(false, false));
        assert!(g.pass(true, false)); // a release sample while dark with no finger down passes harmlessly
    }

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

    fn long_press(t: &mut TouchTracker, x: i16, y: i16, until_ms: u64) -> Vec<Update> {
        let mut out = vec![t.update_at(x, y, true, 0)];
        let mut ms = 100;
        while ms <= until_ms {
            out.push(t.update_at(x, y, true, ms));
            ms += 100;
        }
        out
    }

    #[test]
    fn a_short_touch_is_still_a_tap() {
        let mut t = TouchTracker::new();
        let down = t.update_at(10, 20, true, 0);
        assert!(matches!(down.events.as_slice(), [WindowEvent::PointerPressed { .. }]));
        assert!(t.update_at(10, 20, true, 100).events.is_empty());
        let up = t.update_at(0, 0, false, 200);
        assert!(matches!(up.events.as_slice(), [WindowEvent::PointerReleased { .. }, WindowEvent::PointerExited]));
        assert_eq!(up.gesture, None);
    }

    #[test]
    fn accepted_hold_cancels_pointer_and_emits_holdend() {
        let mut t = TouchTracker::new();
        let steps = long_press(&mut t, 233, 233, 600);
        let starts: Vec<Gesture> = steps.iter().filter_map(|u| u.gesture).collect();
        assert_eq!(starts, [Gesture::HoldStart(233, 233)], "exactly one HoldStart");
        assert!(steps.iter().skip(1).all(|u| u.events.is_empty()), "nothing is cancelled before the app accepts");
        assert!(matches!(t.accept_hold().as_slice(), [WindowEvent::PointerExited]));
        let up = t.update_at(0, 0, false, 700);
        assert!(up.events.is_empty(), "the lift after an accepted hold must not click: {:?}", up.events);
        assert_eq!(up.gesture, Some(Gesture::HoldEnd));
        assert!(matches!(t.update_at(5, 5, true, 800).events.as_slice(), [WindowEvent::PointerPressed { .. }]));
    }

    #[test]
    fn unaccepted_long_press_still_clicks() {
        let mut t = TouchTracker::new();
        let steps = long_press(&mut t, 233, 233, 600);
        assert!(steps.iter().any(|u| matches!(u.gesture, Some(Gesture::HoldStart(..)))));
        let up = t.update_at(0, 0, false, 700);
        assert!(matches!(up.events.as_slice(), [WindowEvent::PointerReleased { .. }, WindowEvent::PointerExited]), "{:?}", up.events);
        assert_eq!(up.gesture, None);
        assert!(t.accept_hold().is_empty(), "nothing to accept once the finger is up");
    }

    #[test]
    fn moving_before_the_threshold_is_not_a_hold() {
        let mut t = TouchTracker::new();
        t.update_at(100, 100, true, 0);
        t.update_at(100 + 2 * HOLD_SLOP_PX, 100, true, 100); // slid away, then stayed there
        let mut gestures = Vec::new();
        for ms in (200..=800).step_by(100) {
            gestures.extend(t.update_at(100 + 2 * HOLD_SLOP_PX, 100, true, ms).gesture);
        }
        assert!(gestures.is_empty());
        assert_eq!(t.update_at(0, 0, false, 900).gesture, None);
    }

    #[test]
    fn a_swipe_is_not_a_hold() {
        let mut t = TouchTracker::new();
        t.update_at(100, 200, true, 0);
        t.update_at(220, 205, true, 100);
        let mut gestures = Vec::new();
        for ms in (200..=800).step_by(100) {
            gestures.extend(t.update_at(220, 205, true, ms).gesture);
        }
        assert!(gestures.is_empty());
        assert_eq!(t.update_at(0, 0, false, 900).gesture, Some(Gesture::SwipeRight));
    }

    fn drag_line(t: &mut TouchTracker, from: (i16, i16), to: (i16, i16)) -> Vec<Update> {
        let mut ups = vec![t.update(from.0, from.1, true)];
        for k in 1..=10 {
            let x = from.0 + (to.0 - from.0) * k / 10;
            let y = from.1 + (to.1 - from.1) * k / 10;
            ups.push(t.update(x, y, true));
        }
        ups.push(t.update(0, 0, false));
        ups
    }

    #[test]
    fn vertical_drags_are_swipes_only_when_turned_on() {
        let mut t = TouchTracker::new();
        let ups = drag_line(&mut t, (233, 300), (233, 150));
        assert_eq!(ups.last().unwrap().gesture, None, "off by default: a vertical drag scrolls");
        assert!(ups.iter().flat_map(|u| u.events.iter()).any(|e| matches!(e, WindowEvent::PointerMoved { .. })));

        t.set_vertical_swipes(true);
        let ups = drag_line(&mut t, (233, 300), (233, 150));
        assert_eq!(ups.last().unwrap().gesture, Some(Gesture::SwipeUp));
        assert!(!ups.iter().flat_map(|u| u.events.iter()).any(|e| matches!(e, WindowEvent::PointerReleased { .. })), "no click under a swipe");
        let ups = drag_line(&mut t, (233, 150), (240, 300));
        assert_eq!(ups.last().unwrap().gesture, Some(Gesture::SwipeDown), "and the setting survives a touch");
    }

    #[test]
    fn a_swipe_down_from_the_top_band_is_an_edge_swipe() {
        let mut t = TouchTracker::new();
        t.set_vertical_swipes(true);
        let ups = drag_line(&mut t, (233, 30), (233, 200));
        assert_eq!(ups.last().unwrap().gesture, Some(Gesture::EdgeDown));
        assert!(!ups.iter().flat_map(|u| u.events.iter()).any(|e| matches!(e, WindowEvent::PointerReleased { .. })));
    }

    #[test]
    fn a_swipe_down_from_lower_is_still_quieter() {
        let mut t = TouchTracker::new();
        t.set_vertical_swipes(true);
        assert_eq!(drag_line(&mut t, (233, 120), (233, 300)).last().unwrap().gesture, Some(Gesture::SwipeDown));
    }

    #[test]
    fn edge_swipes_need_vertical_swipes_on() {
        let mut t = TouchTracker::new();
        assert_eq!(drag_line(&mut t, (233, 30), (233, 200)).last().unwrap().gesture, None);
    }

    #[test]
    fn a_diagonal_drag_from_the_band_is_nothing() {
        let mut t = TouchTracker::new();
        t.set_vertical_swipes(true);
        assert_eq!(drag_line(&mut t, (200, 30), (330, 160)).last().unwrap().gesture, None);
    }

    #[test]
    fn a_diagonal_drag_is_no_vertical_swipe_and_right_still_wins() {
        let mut t = TouchTracker::new();
        t.set_vertical_swipes(true);
        assert_eq!(drag_line(&mut t, (233, 300), (320, 180)).last().unwrap().gesture, None);
        assert_eq!(drag_line(&mut t, (100, 233), (250, 240)).last().unwrap().gesture, Some(Gesture::SwipeRight));
    }
}
