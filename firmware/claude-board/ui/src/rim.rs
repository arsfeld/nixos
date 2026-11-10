//! Geometry of the rim's arcs: an SVG path on the 466 px circle and the tightest even-aligned box around
//! it, so a pulsing arc repaints (and the panel pushes) only that box.

use crate::{RimSegment, SessionState, Tick};

const CENTRE: f32 = 233.0;
/// Radius of the arcs' centre line.
pub const RADIUS: f32 = 220.0;
/// Half the stroke width (5) plus anti-aliasing slack.
const PAD: f32 = 7.0;

fn point(deg: f32, radius: f32) -> (f32, f32) {
    let r = deg.to_radians();
    (CENTRE + radius * r.sin(), CENTRE - radius * r.cos())
}

fn round_down_even(v: f32) -> f32 {
    ((v.floor() as i32) & !1) as f32
}

fn round_up_even(v: f32) -> f32 {
    (((v.ceil() as i32) + 1) & !1) as f32
}

/// The arc from `start_deg` to `end_deg` (clockwise from the top) on the rim. Drawn as two halves, so any sweep up
/// to 359 degrees is a valid SVG arc.
pub fn arc_segment(start_deg: f32, end_deg: f32, state: SessionState) -> RimSegment {
    arc_segment_at(start_deg, end_deg, RADIUS, PAD, state)
}

/// `arc_segment` on a circle of `radius`, for a stroke of up to `2 * half_stroke` (the box is padded by it).
pub fn arc_segment_at(start_deg: f32, end_deg: f32, radius: f32, half_stroke: f32, state: SessionState) -> RimSegment {
    let point = |deg| point(deg, radius);
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
    let (x0, y0) = (round_down_even(min_x - half_stroke), round_down_even(min_y - half_stroke));
    let (x1, y1) = (round_up_even(max_x + half_stroke), round_up_even(max_y + half_stroke));
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
            r = radius
        )
        .into(),
        state,
    }
}

/// Half the ticks' stroke width (8) plus a pixel of anti-aliasing slack.
const TICK_PAD: f32 = 5.0;

/// `n` radial ticks from `r_in` to `r_out`, spread evenly from `from_deg` to `to_deg` inclusive (clockwise from the
/// top). Each is one straight line with its own even-aligned box, so lighting one repaints only that box. The volume
/// page's level and the purge page's ring are both made of these.
pub fn ticks(from_deg: f32, to_deg: f32, n: usize, r_in: f32, r_out: f32) -> Vec<Tick> {
    (0..n)
        .map(|i| {
            let deg = if n > 1 { from_deg + (to_deg - from_deg) * i as f32 / (n - 1) as f32 } else { from_deg };
            let (a, b) = (point(deg, r_in), point(deg, r_out));
            let (x0, y0) = (round_down_even(a.0.min(b.0) - TICK_PAD), round_down_even(a.1.min(b.1) - TICK_PAD));
            let (x1, y1) = (round_up_even(a.0.max(b.0) + TICK_PAD), round_up_even(a.1.max(b.1) + TICK_PAD));
            Tick {
                x: x0,
                y: y0,
                width: x1 - x0,
                height: y1 - y0,
                commands: format!("M {:.1} {:.1} L {:.1} {:.1}", a.0, a.1, b.0, b.1).into(),
            }
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn volume_ticks_are_symmetric_with_tight_boxes() {
        let t = ticks(-120.0, 120.0, 24, 195.0, 221.0);
        assert_eq!(t.len(), 24);
        let (first, last) = (&t[0], &t[23]);
        // Mirror images about x = 233: the left edge of one and the right edge of the other.
        assert!((first.x + last.x + last.width - 466.0).abs() <= 2.0, "{} {} {}", first.x, last.x, last.width);
        assert_eq!(first.y, last.y);
        assert_eq!(first.height, last.height);
        for k in &t {
            assert!(k.width < 40.0 && k.height < 40.0, "{} x {}", k.width, k.height);
            assert!(k.x as i32 % 2 == 0 && k.y as i32 % 2 == 0, "even-aligned");
            assert!(k.x >= 0.0 && k.y >= 0.0 && k.x + k.width <= 466.0 && k.y + k.height <= 466.0);
        }
    }

    #[test]
    fn ring_ticks_go_round_once() {
        let t = ticks(0.0, 350.0, 36, 200.0, 222.0);
        assert_eq!(t.len(), 36);
        // The first stands at the top, centred on x = 233.
        assert!((t[0].x + t[0].width / 2.0 - 233.0).abs() <= 1.0);
        assert!(t[0].y < 15.0);
        for k in &t {
            assert!(k.width < 40.0 && k.height < 40.0, "{} x {}", k.width, k.height);
        }
    }
}
