//! Geometry of the rim's arcs: an SVG path on the 466 px circle and the tightest even-aligned box around
//! it, so a pulsing arc repaints (and the panel pushes) only that box.

use crate::{RimSegment, SessionState};

const CENTRE: f32 = 233.0;
/// Radius of the arcs' centre line.
pub const RADIUS: f32 = 220.0;
/// Half the stroke width (5) plus anti-aliasing slack.
const PAD: f32 = 7.0;

fn point(deg: f32) -> (f32, f32) {
    let r = deg.to_radians();
    (CENTRE + RADIUS * r.sin(), CENTRE - RADIUS * r.cos())
}

fn round_down_even(v: f32) -> f32 {
    ((v.floor() as i32) & !1) as f32
}

fn round_up_even(v: f32) -> f32 {
    (((v.ceil() as i32) + 1) & !1) as f32
}

/// The arc from `start_deg` to `end_deg` (clockwise from the top). Drawn as two halves, so any sweep up to
/// 359 degrees is a valid SVG arc.
pub fn arc_segment(start_deg: f32, end_deg: f32, state: SessionState) -> RimSegment {
    let mid = (start_deg + end_deg) / 2.0;
    let (p0, pm, p1) = (point(start_deg), point(mid), point(end_deg));
    let (mut min_x, mut max_x, mut min_y, mut max_y) = (f32::MAX, f32::MIN, f32::MAX, f32::MIN);
    for k in 0..=40 {
        let (x, y) = point(start_deg + (end_deg - start_deg) * k as f32 / 40.0);
        min_x = min_x.min(x);
        max_x = max_x.max(x);
        min_y = min_y.min(y);
        max_y = max_y.max(y);
    }
    let (x0, y0) = (round_down_even(min_x - PAD), round_down_even(min_y - PAD));
    let (x1, y1) = (round_up_even(max_x + PAD), round_up_even(max_y + PAD));
    RimSegment {
        x: x0,
        y: y0,
        width: x1 - x0,
        height: y1 - y0,
        commands: format!(
            "M {:.1} {:.1} A {r} {r} 0 0 1 {:.1} {:.1} A {r} {r} 0 0 1 {:.1} {:.1}",
            p0.0,
            p0.1,
            pm.0,
            pm.1,
            p1.0,
            p1.1,
            r = RADIUS
        )
        .into(),
        state,
    }
}
