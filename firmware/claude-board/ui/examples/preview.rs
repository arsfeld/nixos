//! Renders each screen and state to a PNG, so layout is reviewed without flashing the board:
//! `just board preview` (output in firmware/claude-board/preview/). A circle mask shows the panel's shape.

use std::path::Path;

use claude_board_ui::headless::{headless, rgb, Headless, HEIGHT, WIDTH};
use claude_board_proto::{Model, Session, State};
use claude_board_ui::view::{rim_models, session_rows};
use claude_board_ui::{AppWindow, OptionRow, Page, PresenceState, RimSegment, SessionState};
use slint::{ComponentHandle, ModelRc, SharedString, VecModel};

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

fn sess(host: &str, project: &str, state: State, ago: i64) -> Session {
    Session { host: host.into(), session: format!("{host}-{project}"), project: project.into(), cwd: String::new(), state, since: NOW - ago }
}

const NOW: i64 = 1_800_000_000;

fn five() -> Vec<Session> {
    let mut m = Model::new();
    let all = [
        sess("galactica", "claude-board", State::Waiting, 40),
        sess("raider", "nixos", State::Working, 240),
        sess("basestar", "k3s", State::Done, 720),
        sess("pegasus", "media-sync", State::Idle, 7200),
        sess("blackbird", "dotfiles", State::Error, 3600),
    ];
    m.apply(&serde_json::to_string(&serde_json::json!({"t":"state","sessions":all})).unwrap());
    m.sessions().to_vec()
}

fn show_rim(ui: &AppWindow, sessions: &[Session]) {
    let (still, pulsing) = rim_models(sessions);
    ui.set_rim(model(still));
    ui.set_rim_pulsing(model(pulsing));
}

fn options(labels: &[(&str, bool)]) -> ModelRc<OptionRow> {
    ModelRc::new(VecModel::from(labels.iter().map(|(l, sel)| OptionRow { label: SharedString::from(*l), selected: *sel }).collect::<Vec<_>>()))
}

fn settle(h: &Headless) {
    for _ in 0..8 {
        h.step(33);
    }
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

    let sessions = five();
    show_rim(&ui, &sessions);
    ui.set_page(Page::Home);
    ui.set_presence_state(PresenceState::Alert);
    ui.set_presence_level(0.0);
    ui.set_summary("1 needs you".into());
    settle(&h);
    write_png(dir, "home-alert", &h);

    ui.set_presence_state(PresenceState::Idle);
    ui.set_summary("All quiet".into());
    ui.set_link(false);
    write_png(dir, "home-offline", &h);
    ui.set_link(true);

    ui.set_page(Page::List);
    ui.set_rows(ModelRc::new(VecModel::from(session_rows(&sessions, Some(NOW)))));
    ui.set_list_header("5 SESSIONS - 1 NEEDS YOU".into());
    write_png(dir, "list", &h);

    ui.set_page(Page::Question);
    ui.set_question_source("GALACTICA - CLAUDE-BOARD".into());
    ui.set_question_text("Which base should the Rust rewrite use?".into());
    ui.set_multi(false);
    ui.set_options(options(&[("esp-idf-svc + Slint", false), ("esp-hal bare-metal", false), ("Probe both first", false)]));
    write_png(dir, "question-single", &h);

    ui.set_multi(true);
    ui.set_can_done(true);
    ui.set_question_text("Which toppings?".into());
    ui.set_options(options(&[("Nuts", true), ("Cream", false), ("Honey", true), ("Chocolate", false)]));
    write_png(dir, "question-multi", &h);

    ui.set_multi(false);
    ui.set_question_source("RAIDER - NIXOS".into());
    ui.set_question_text("🎨 Cuál es tu color favorito? Écoute ça: 日本語 Ωμέγα".into());
    ui.set_options(options(&[("Α β ✓ café", false), ("日本語 テスト", false), ("Ünï cödé", false)]));
    write_png(dir, "question-unicode", &h);

    ui.set_page(Page::Detail);
    ui.set_detail_host("galactica".into());
    ui.set_detail_project("claude-board".into());
    ui.set_detail_state(SessionState::Waiting);
    ui.set_detail_state_text("waiting".into());
    ui.set_detail_since("40s".into());
    write_png(dir, "detail", &h);

    // The list at several wheel curvatures, side by side (scrolled so rows sit above and below the centre).
    let mut many8 = Model::new();
    let eight: Vec<Session> = (0..8)
        .map(|i| {
            let (name, st) = [("claude-board", State::Waiting), ("nixos", State::Working), ("k3s", State::Done), ("media-sync", State::Idle), ("dotfiles", State::Error), ("plab", State::Working), ("blog", State::Done), ("immich", State::Idle)][i];
            sess(["galactica", "raider", "basestar", "pegasus", "blackbird", "galactica", "basestar", "galactica"][i], name, st, 40 + 300 * i as i64)
        })
        .collect();
    many8.apply(&serde_json::to_string(&serde_json::json!({"t":"state","sessions":eight})).unwrap());
    show_rim(&ui, many8.sessions());
    ui.set_rows(ModelRc::new(VecModel::from(session_rows(many8.sessions(), Some(NOW)))));
    ui.set_list_header("8 SESSIONS - 1 NEEDS YOU".into());
    ui.set_page(Page::List);
    ui.set_list_scroll(-2.0 * 56.0);
    write_png(dir, "list-wheel", &h);

    // A crowded rim: 13 sessions, two waiting.
    let mut many = Model::new();
    let all: Vec<Session> = (0..13).map(|i| sess("h", &format!("p{i}"), if i < 2 { State::Waiting } else { State::Idle }, i)).collect();
    many.apply(&serde_json::to_string(&serde_json::json!({"t":"state","sessions":all})).unwrap());
    show_rim(&ui, many.sessions());
    ui.set_page(Page::Home);
    ui.set_summary("2 need you".into());
    ui.set_presence_state(PresenceState::Alert);
    settle(&h);
    write_png(dir, "rim-13-sessions", &h);
}
