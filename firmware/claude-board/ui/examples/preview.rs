//! Renders each screen and state to a PNG, so layout is reviewed without flashing the board:
//! `just board preview` (output in firmware/claude-board/preview/). A circle mask shows the panel's shape.

use std::path::Path;

use claude_board_ui::headless::{headless, rgb, Headless, HEIGHT, WIDTH};
use claude_board_ui::rim::arc_segment;
use claude_board_ui::{AppWindow, PresenceState, RimSegment, SessionState};
use slint::{ComponentHandle, ModelRc, VecModel};

fn write_png(dir: &Path, name: &str, h: &Headless) {
    let buf = h.render();
    let mut out = Vec::with_capacity(WIDTH * HEIGHT * 3);
    for y in 0..HEIGHT {
        for x in 0..WIDTH {
            let (dx, dy) = (x as f32 + 0.5 - 233.0, y as f32 + 0.5 - 233.0);
            if dx * dx + dy * dy > 233.0 * 233.0 {
                out.extend([24, 24, 28]); // outside the round panel
            } else {
                let (r, g, b) = rgb(buf[y * WIDTH + x]);
                out.extend([r, g, b]);
            }
        }
    }
    let file = std::fs::File::create(dir.join(format!("{name}.png"))).unwrap();
    let mut enc = png::Encoder::new(file, WIDTH as u32, HEIGHT as u32);
    enc.set_color(png::ColorType::Rgb);
    enc.set_depth(png::BitDepth::Eight);
    enc.write_header().unwrap().write_image_data(&out).unwrap();
    println!("wrote {name}.png");
}

fn model(v: Vec<RimSegment>) -> ModelRc<RimSegment> {
    ModelRc::new(VecModel::from(v))
}

/// Five sessions, one waiting: the waiting arc pulses.
fn demo_rim(ui: &AppWindow) {
    let states = [SessionState::Waiting, SessionState::Working, SessionState::Done, SessionState::Idle, SessionState::Error];
    let arc = |i: usize| (i as f32 * 72.0 + 3.5, (i + 1) as f32 * 72.0 - 3.5);
    let still = states.iter().enumerate().skip(1).map(|(i, s)| arc_segment(arc(i).0, arc(i).1, *s)).collect();
    ui.set_rim(model(still));
    ui.set_rim_pulsing(model(vec![arc_segment(arc(0).0, arc(0).1, states[0])]));
}

fn main() {
    let dir = std::env::args().nth(1).unwrap_or_else(|| "preview".into());
    let dir = Path::new(&dir);
    std::fs::create_dir_all(dir).unwrap();
    let h = headless();
    let ui = AppWindow::new().unwrap();
    ui.show().unwrap();

    for (name, state, level) in [
        ("presence-idle", PresenceState::Idle, 0.0),
        ("presence-listening", PresenceState::Listening, 0.5),
        ("presence-thinking", PresenceState::Thinking, 0.0),
        ("presence-speaking", PresenceState::Speaking, 0.8),
        ("presence-alert", PresenceState::Alert, 0.0),
    ] {
        ui.set_presence_state(state);
        ui.set_presence_level(level);
        write_png(dir, name, &h);
    }

    demo_rim(&ui);
    ui.set_presence_state(PresenceState::Alert);
    ui.set_presence_level(0.0);
    for _ in 0..8 {
        h.step(33);
    }
    write_png(dir, "home-alert", &h);
}
