# Cylon Bot Rust and Slint Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the C and LVGL board firmware with Rust and Slint on `esp-idf-svc`, with a shared protocol crate, a rim-gauge UI around a drawn `Presence` avatar, and every feature of today's firmware.

**Architecture:** Three Rust pieces and one small C component. `cylon-bot-proto` (shared with the bridge) owns the wire types and the board's model. `cylon-bot-ui` (host and device) owns the Slint screens and the controller that turns model changes into screen properties. `firmware/cylon-bot/app` is the ESP-IDF binary: Wi-Fi, SNTP, websocket, a Slint platform, and `board_display`, the C component that keeps Waveshare's panel, touch and audio init. A throwaway probe comes first and gates the rest.

**Tech Stack:** Rust (Espressif Xtensa fork), `esp-idf-svc`/`esp-idf-sys`, Slint (software renderer, GPLv3), serde, ESP-IDF 5.5.4 via `nixpkgs-esp-dev`, `espflash`, just, Nix.

**Spec:** `docs/superpowers/specs/2026-11-09-cylon-bot-rust-design.md`. Mockups: https://claude.ai/artifact/NJ6PUSJkS1bXuoCdUDniV4 (direction A).

## Global Constraints

- Commit straight to master, no branches or worktrees. Conventional commits: `<type>(<scope>)`, scope `raider` for firmware, `galactica` for the bridge and proto crate, `modules` for the dev shell. Never mention Claude as author.
- New files and directories are invisible to `nix build` until `git add`ed.
- Never build or evaluate `cylon-link`. Evaluate one host at a time, niced. Do not run `nix flake check` locally.
- Do not deploy without asking the user first. Deploying the bridge (`just deploy galactica`) is outward-facing.
- Never flash without a full-flash backup in `~/.local/share/esp32-amoled/` (`just board backup`).
- ESP-IDF stays at v5.5.4. Panel is 466 x 466 round AMOLED. The ESP32-S3 is 2.4 GHz only.
- The server certificate is always validated against the full certificate bundle, and the board does not connect until the clock is set. There is no insecure mode.
- Secrets (Wi-Fi SSID and password, device token) come from sops through `just board creds` into a gitignored file. Never print them.
- `AWAKE_MS` = 30000, `BRIGHT_AWAKE` = 70, `BRIGHT_IDLE` = 8. State colours: working `0x3b82f6`, waiting `0xf59e0b`, idle `0x6b7280`, done `0x22c55e`, error `0xef4444`.
- The JSON fixtures in `packages/cylon-bot-bridge/tests/fixtures/board/*.json` are the wire contract.
- Slint is used under GPLv3. Fonts embedded in the firmware must have open licences (Sora, JetBrains Mono).
- No NSFW names or terms anywhere in the repo.

## Review Focus

Inputs the spec implies that no task's main tests would otherwise hit. Each has a test in the owning task.

1. **Unknown or newer messages** (a `hello` with a future version, an unknown `t`, extra fields): ignored, never a crash or a dropped session list. Task 6.
2. **Zero, one and many sessions on the rim** (0, 1, 13, 40): no overflow, waiting sessions never hidden. Task 8.
3. **Stale multi-select after a bridge restart:** a `state` snapshot arrives while a question is on screen, then the same question comes back with the same id. Checked boxes from before must not carry over. Task 9.
4. **Double tap on an answer:** the answer is sent once. Task 9.
5. **Clock unset or Wi-Fi down:** "time in state" shows `--`, nothing connects, and the screen still shows sessions it already has. Tasks 8, 9 and 13.

---

## Phase 0: probe (throwaway)

Everything in `firmware/probe-rust/` is labelled throwaway and deleted in Task 14. Its output is `docs/superpowers/specs/2026-11-09-cylon-bot-rust-probe-findings.md` (Task 4) and a go or no-go.

### Task 1: Probe A, toolchain and build

**Files:**
- Modify: `modules/flake/dev.nix` (the `devShells.firmware` block)
- Create: `firmware/probe-rust/Cargo.toml`, `firmware/probe-rust/rust-toolchain.toml`, `firmware/probe-rust/.cargo/config.toml`, `firmware/probe-rust/build.rs`, `firmware/probe-rust/src/main.rs`, `firmware/probe-rust/README.md`

**Interfaces:**
- Produces: `nix develop .#firmware -c cargo build` inside `firmware/probe-rust` links an `xtensa-esp32s3-espidf` binary against the nix ESP-IDF 5.5.4, with `espflash` available in the shell. Later tasks reuse the dev-shell changes.

- [ ] **Step 1: Find a reproducible Xtensa Rust toolchain for the dev shell.** Candidates in order: a package already exposed by the `nixpkgs-esp-dev` input, then a flake-input packaging of the Espressif rust fork (`esp-rs-nix` style), then `espup` into a fixed directory as a last resort. Check with `nix flake show` and `nix search` before adding an input. Record what you chose and why in `firmware/probe-rust/README.md`.
- [ ] **Step 2: Add the toolchain, `espflash`, `ldproxy` and `cargo` to `devShells.firmware`.** Set `IDF_PATH` and `ESP_IDF_TOOLS_INSTALL_DIR=fromenv` so `esp-idf-sys` uses the nix ESP-IDF instead of downloading its own.
- [ ] **Step 3: Build a hello binary.** `src/main.rs` calls `esp_idf_svc::sys::link_patches()`, initialises logging, and logs "probe alive". `Cargo.toml` pins `esp-idf-svc` and `esp-idf-sys` to the newest releases that claim ESP-IDF 5.x support. `.cargo/config.toml` sets target `xtensa-esp32s3-espidf`, runner `espflash`, `build-std = ["std","panic_abort"]` and `ESP_IDF_VERSION=v5.5.4`.
- [ ] **Step 4: Run `nix develop .#firmware -c bash -c 'cd firmware/probe-rust && cargo build --release'`.** Expected: finishes and prints an ELF path. If `esp-idf-sys` refuses 5.5.4, retry once with the `nixpkgs-esp-dev` override pinned to the newest 5.4.x and record that this is needed. If both fail, stop and report to the user: this answers probe question 1 with "no".
- [ ] **Step 5: Run `just board backup`, then flash with `espflash flash --monitor` and see "probe alive" on serial.** Expected: log line appears. Skip flashing (record "not flashed") only if the user says the board is unavailable.
- [ ] **Step 6: Commit.** `git add modules/flake/dev.nix firmware/probe-rust` then `git commit -m "chore(modules): add rust esp toolchain to the firmware dev shell"`.

### Task 2: Probe B, Wi-Fi, TLS and websocket from Rust

**Files:**
- Modify: `firmware/probe-rust/src/main.rs`, `firmware/probe-rust/build.rs`, `just/board.just` (a `creds` variant, see Step 1)
- Create: `firmware/probe-rust/sdkconfig.defaults`

**Interfaces:**
- Consumes: Task 1's dev shell and build.
- Produces: proof that `EspWifi`, `EspSntp` and `EspWebSocketClient` with the certificate bundle reach `wss://cylon-bot.arsfeld.one/v1/board` and receive a `state` message. Also a working `credentials.env` convention reused by Task 11.

- [ ] **Step 1: Extend `just board creds` to also write `firmware/probe-rust/credentials.env`** (gitignored) with `CB_WIFI_SSID`, `CB_WIFI_PASS`, `CB_TOKEN`, from the same three sops secrets it uses today. Keep writing `sdkconfig.defaults.local` for the C firmware until Task 14. `build.rs` turns each into a `cargo:rustc-env`.
- [ ] **Step 2: Copy the Wi-Fi, mbedTLS-in-PSRAM, PSRAM and DMA-pool lines from `firmware/cylon-bot/sdkconfig.defaults` into the probe's `sdkconfig.defaults`,** leaving out every `CONFIG_LV_*` line. Add `CONFIG_MBEDTLS_CERTIFICATE_BUNDLE=y` and `CONFIG_MBEDTLS_CERTIFICATE_BUNDLE_DEFAULT_FULL=y`.
- [ ] **Step 3: In `main.rs`, connect Wi-Fi (WPA2 minimum), wait for SNTP to set the clock, then open the websocket** with the header `Authorization: Bearer <token>`, `crt_bundle_attach: Some(esp_crt_bundle_attach)`, and log the first text frame's first 80 bytes. Do not connect before the clock is set.
- [ ] **Step 4: Build, flash, monitor.** Expected: log shows a frame starting `{"t":"state"`. Also log `heap_caps_get_free_size(MALLOC_CAP_INTERNAL)` and the largest DMA block every 30 s, as `main.c` does today.
- [ ] **Step 5: Commit.** `git commit -m "chore(raider): probe wifi tls websocket from rust"`.

### Task 3: Probe C, Slint on the panel

**Files:**
- Create: `firmware/probe-rust/components/board_display/{CMakeLists.txt,board_display.h,board_display.c,idf_component.yml}`, `firmware/probe-rust/src/slint_probe.rs`, `firmware/probe-rust/ui/probe.slint`
- Modify: `firmware/probe-rust/Cargo.toml`, `firmware/probe-rust/src/main.rs`

**Interfaces:**
- Produces (C, reused verbatim by Task 10 in `app/components/board_display`):
  ```c
  typedef struct { int16_t x, y; bool pressed; } bd_touch_t;
  esp_err_t bd_init(void);                      // panel, touch, brightness; no LVGL
  esp_err_t bd_draw(int x0, int y0, int x1, int y1, const uint16_t *rgb565); // x1,y1 exclusive; returns when the data has been sent
  bool      bd_touch_read(bd_touch_t *out);     // latest touch state
  void      bd_set_brightness(uint8_t percent);
  void      bd_chime(void);                     // non-blocking, ignored if played in the last few seconds
  ```

- [ ] **Step 1: Write `board_display.c` from the BSP.** Use the Waveshare BSP's panel and touch creation functions without `esp_lvgl_port` (check whether the BSP exposes `bsp_display_new`; if it forces LVGL in, write the panel init with `esp_lcd` directly from the BSP source and record that in the findings). Implement `bd_chime` by moving `main/chime.c` here unchanged in behaviour.
- [ ] **Step 2: Wire the component into `esp-idf-sys`** with `component_dirs` and `extra_components` in `Cargo.toml` metadata, add the BSP as a remote component, and generate bindings for `board_display.h`.
- [ ] **Step 3: Write the probe scene `probe.slint`:** a rim of 5 coloured arcs, a breathing orb in the centre, and an animated `level` ring, all running continuously. Show the measured frames per second as text.
- [ ] **Step 4: Implement the Slint platform in `slint_probe.rs`:** a `MinimalSoftwareWindow`, `render_by_line` into a line buffer, batches of 8 lines accumulated in one DMA-capable internal buffer (466 x 8 x 2 bytes) and sent with `bd_draw`. Pointer events come from `bd_touch_read`. Verify the colour byte order on screen: red must look red; swap bytes if not.
- [ ] **Step 5: Measure on the board with Wi-Fi and the websocket from Task 2 connected, for 2 minutes.** Record frames per second, free internal RAM, largest DMA block, and flash image size. Add one embedded font (Sora, subset) and record the size delta.
- [ ] **Step 6: Commit.** `git commit -m "chore(raider): probe slint on the amoled panel"`.

### Task 4: Probe findings and go or no-go

**Files:**
- Create: `docs/superpowers/specs/2026-11-09-cylon-bot-rust-probe-findings.md`

- [ ] **Step 1: Write the findings:** one section each for the spec's four questions plus "does the BSP work without LVGL", with the numbers. State proposed gates and whether each passed: sustained at least 24 frames per second on the probe scene; internal free RAM at least 80 KB with Wi-Fi and TLS up (today's firmware has about 118 KB); ESP-IDF 5.5.4 builds, or the version that was needed; the toolchain is reproducible from `nix develop .#firmware`. Treat these gates as proposals the user may change.
- [ ] **Step 2: Commit.** `git commit -m "docs(raider): record the rust firmware probe findings"`.
- [ ] **Step 3: Stop and report to the user.** Do not start Task 5 until they say go. If a gate failed, the spec's fallback applies (LVGL stays, protocol and network move to Rust) and this plan needs a rewrite for it.

---

## Phase 1: build (after a go)

### Task 5: Shared protocol crate and hello message

**Files:**
- Create: `packages/cylon-bot-proto/{Cargo.toml,src/lib.rs}`
- Modify: `packages/cylon-bot-bridge/Cargo.toml`, `packages/cylon-bot-bridge/package.nix`, `packages/cylon-bot-bridge/src/protocol.rs`, `packages/cylon-bot-bridge/src/asks.rs`, `packages/cylon-bot-bridge/src/board.rs`
- Create: `packages/cylon-bot-bridge/tests/fixtures/board/hello.json`
- Test: `packages/cylon-bot-bridge/tests/wire.rs`, `packages/cylon-bot-proto/src/lib.rs` (unit tests)

**Interfaces:**
- Produces, in crate `cylon_bot_proto` (edition 2024, deps `serde`, `serde_json`):
  ```rust
  pub const PROTOCOL_VERSION: u32 = 1;
  pub enum State { Idle, Working, Waiting, Done, Error }              // serde lowercase, Copy
  pub struct Session { host: String, session: String, project: String, cwd: String, state: State, since: i64 }
  pub struct AskId(pub String);                                       // serde transparent
  pub struct QuestionOption { label: String, description: Option<String> }
  pub struct Question { question: String, header: Option<String>, options: Vec<QuestionOption>, multi_select: bool } // camelCase
  pub struct PendingAsk { id: AskId, host: String, session: String, project: String, questions: Vec<Question> }
  pub enum BoardMsg { Hello { version: u32 }, State { sessions: Vec<Session> }, Upsert { session: Session },
                      Remove { host: String, session: String }, Question { ask: PendingAsk }, QuestionClear { id: AskId },
                      Unknown }                                       // tag "t", snake_case, Serialize + Deserialize, #[serde(other)] on Unknown
  pub enum ClientMsg { Answer { id: AskId, answers: BTreeMap<String, String> }, Decline { id: AskId } } // tag "t", snake_case, both derives
  ```
  All `pub` fields. The bridge keeps its own `Event`, `EventKind`, `Answered` and ask registry.

- [ ] **Step 1: Write failing tests in the proto crate:** `hello_fixture_round_trips` (parse `{"t":"hello","version":1}`), `every_board_fixture_round_trips_through_boardmsg` (loop over all fixtures in the bridge's fixture directory except `question_clear` variants that need ids, parse then re-serialise and compare as `serde_json::Value`), `unknown_t_parses_as_unknown` (`{"t":"future","x":1}`), `unknown_fields_are_ignored` (extra key on `upsert`), `client_answer_and_decline_serialise_to_the_firmware_shape` (`{"t":"answer","id":"..","answers":{"Which colour?":"Red"}}`).
- [ ] **Step 2: Run `cargo test` in `packages/cylon-bot-proto`.** Expected: FAIL, nothing defined.
- [ ] **Step 3: Move the types listed above out of `protocol.rs`, `asks.rs` and `board.rs` into the proto crate and re-export them from the bridge** (`pub use cylon_bot_proto::{...}` in `protocol.rs` and `asks.rs`) so existing bridge code and tests keep their imports. Add `hello.json` and make the bridge send `BoardMsg::Hello { version: PROTOCOL_VERSION }` as the first frame of a board connection, before `State`.
- [ ] **Step 4: Point `packages/cylon-bot-bridge/Cargo.toml` at the crate by path and widen `package.nix`'s `fileset` and `src` root** so both directories are in the source (set `sourceRoot` to the bridge directory). Extend `tests/wire.rs` with `hello_matches_the_firmware_fixture`.
- [ ] **Step 5: Run `cargo test` in both crates, then `nix build .#cylon-bot-bridge`.** Expected: all pass. The C firmware ignores the new `hello` as an unknown type (`BP_IGNORED`), so rolling the bridge out first is safe.
- [ ] **Step 6: Commit.** `git add packages/cylon-bot-proto packages/cylon-bot-bridge && git commit -m "feat(galactica): share the board wire types and announce the protocol version"`. Ask the user before running `just deploy galactica`.

### Task 6: Board model in Rust

**Files:**
- Create: `packages/cylon-bot-proto/src/model.rs`
- Modify: `packages/cylon-bot-proto/src/lib.rs` (`pub mod model; pub use model::*;`), `just/board.just` (the `test` recipe), `modules/flake/checks.nix` (new check)
- Test: `packages/cylon-bot-proto/src/model.rs` (unit tests, ported from `firmware/cylon-bot/components/board_proto/test/test_board_proto.c`)

**Interfaces:**
- Consumes: Task 5's types.
- Produces:
  ```rust
  pub enum Applied { Changed, Ignored, Malformed }
  pub struct Ask { pub ask: PendingAsk, /* answers, dismissed private */ }
  impl Ask { pub fn next_question(&self) -> usize; pub fn current(&self) -> &Question }
  pub enum AnswerOutcome { NextQuestion, Complete(ClientMsg), NoQuestion }
  pub struct Model { /* private */ }
  impl Model {
      pub fn new() -> Self;
      pub fn apply(&mut self, json: &str) -> Applied;
      pub fn sessions(&self) -> &[Session];             // waiting first, then newest `since` first
      pub fn waiting_count(&self) -> usize;
      pub fn current_ask(&self) -> Option<&Ask>;        // oldest not dismissed and not fully answered
      pub fn ask_count(&self) -> usize;                 // includes answered ones awaiting question_clear
      pub fn dismiss(&mut self, id: &AskId);
      pub fn answer(&mut self, label: &str) -> AnswerOutcome;
      pub fn decline_msg(&self) -> Option<ClientMsg>;   // for current_ask
  }
  pub fn join_labels(labels: &[&str]) -> String;        // joined with ","
  pub fn fit(s: &str, max_bytes: usize) -> usize;       // bytes to show, never inside a character
  ```
  Behaviour to match the C model: a `state` snapshot replaces every session and drops every held ask; `upsert` replaces by `(host, session)`; `remove` drops one; `question` appends; `question_clear` removes by id; `hello` and unknown types return `Ignored`; invalid JSON returns `Malformed` and leaves the model unchanged.

- [ ] **Step 1: Port the C tests as Rust unit tests that load the fixtures from the bridge's fixture directory.** Names and assertions: `state_fixture_sorts_waiting_first` (order is `s-2`, `s-3`, `s-1`), `upsert_replaces_by_host_and_session`, `remove_drops_the_session`, `single_question_becomes_current_ask`, `multi_question_fixture_needs_all_answers_before_complete`, `answer_complete_uses_the_exact_question_text_as_key`, `unicode_question_text_is_kept_intact_in_the_answer_key`, `decline_msg_matches_the_wire_shape`, `dismissed_ask_is_not_current_but_still_counted_until_clear`, `question_clear_removes_it`, `state_snapshot_drops_held_asks`, `join_labels_uses_commas`, `fit_never_splits_a_char` (`"héllo"` with max 2 returns 1; with max 3 returns 3), `answer_with_no_ask_is_noask`. Add Review Focus 1: `hello_with_a_future_version_is_ignored`, `unknown_type_is_ignored_and_changes_nothing`, `malformed_json_leaves_the_model_unchanged`, `unknown_fields_on_upsert_are_ignored`.
- [ ] **Step 2: Run `cargo test -p cylon-bot-proto`.** Expected: FAIL.
- [ ] **Step 3: Implement `Model` in `model.rs`** keeping asks in arrival order and sessions in a `Vec` re-sorted on every change.
- [ ] **Step 4: Run the tests.** Expected: PASS.
- [ ] **Step 5: Replace the body of the `test` recipe in `just/board.just` with `cargo test -p cylon-bot-proto`** run in the firmware dev shell (leave the C recipe as `test-c` until Task 14), and add a flake check `cylon-bot-proto-tests` in `modules/flake/checks.nix` that runs the crate's tests with `rustPlatform.buildRustPackage`, `installPhase = "touch $out"`.
- [ ] **Step 6: Run `just board test`.** Expected: all pass. Do not run `nix flake check`; build the one check with `nix build .#checks.x86_64-linux.cylon-bot-proto-tests`.
- [ ] **Step 7: Commit.** `git commit -m "feat(raider): port the board model to rust"`.

### Task 7: UI crate with theme, Rim and Presence

**Files:**
- Create: `firmware/cylon-bot/Cargo.toml` (workspace, members `ui`), `firmware/cylon-bot/ui/Cargo.toml`, `firmware/cylon-bot/ui/build.rs`, `firmware/cylon-bot/ui/src/lib.rs`, `firmware/cylon-bot/ui/ui/{theme,presence,rim,app}.slint`, `firmware/cylon-bot/ui/fonts/` (Sora, JetBrains Mono subsets and their licence files), `firmware/cylon-bot/ui/src/preview.rs`, `firmware/cylon-bot/ui/examples/preview.rs`
- Modify: `just/board.just` (new `preview` recipe)
- Test: `firmware/cylon-bot/ui/tests/render.rs`

**Interfaces:**
- Produces (Slint, in `theme.slint`): global `Theme` with the state colours and `bg`, `card`, `text`, `muted`. In `presence.slint`: component `Presence` with `in property <PresenceState> state` (enum `idle, listening, thinking, speaking, alert`) and `in property <float> level` (0 to 1). In `rim.slint`: component `Rim` with `in property <[RimSegment]> segments` where `struct RimSegment { start-deg: float, end-deg: float, state: SessionState }` and `enum SessionState { idle, working, waiting, done, error }`.
- Produces (Rust): `pub fn render_to_rgb565(window: &AppWindow, width: u32, height: u32) -> Vec<Rgb565Pixel>` and `examples/preview.rs` writing one PNG per screen and state into a directory given as the first argument. The `ui` crate builds on the host and for the ESP target.

- [ ] **Step 1: Write failing render tests in `tests/render.rs`** using Slint's `MinimalSoftwareWindow` and a headless platform: `presence_alert_draws_amber_pixels_near_the_centre`, `presence_idle_draws_no_amber`, `rim_draws_each_segment_in_its_state_colour` (one segment per state; sample the pixel at the arc midpoint on radius 220 and compare with `Theme` colours within a tolerance of 24 per channel), `rim_with_no_segments_leaves_the_ring_area_black`.
- [ ] **Step 2: Run `cargo test -p cylon-bot-ui`.** Expected: FAIL.
- [ ] **Step 3: Write the `.slint` components to match direction A of the mockups:** rim stroke 10 px at radius 220 with round caps, the waiting arc pulsing; `Presence` is a core orb with a halo and two rings whose motion derives only from `state` and `level`; fonts loaded with `import "fonts/..."`. Compile `.slint` from `build.rs`.
- [ ] **Step 4: Write `examples/preview.rs` and the `just board preview` recipe.** Output goes to `firmware/cylon-bot/preview/` (gitignored). Open two or three PNGs and compare them with the mockups.
- [ ] **Step 5: Run the tests.** Expected: PASS.
- [ ] **Step 6: Commit.** `git commit -m "feat(raider): add slint theme, rim and presence avatar"`.

### Task 8: Screens and view logic

**Files:**
- Create: `firmware/cylon-bot/ui/ui/{home,sessions,question,detail}.slint`, `firmware/cylon-bot/ui/src/view.rs`
- Modify: `firmware/cylon-bot/ui/ui/app.slint`, `firmware/cylon-bot/ui/src/lib.rs`, `firmware/cylon-bot/ui/examples/preview.rs`
- Test: `firmware/cylon-bot/ui/src/view.rs` (unit tests)

**Interfaces:**
- Consumes: Task 6's `Model`, `Session`, `State`; Task 7's `Rim`, `Presence`.
- Produces (Rust, `view.rs`):
  ```rust
  pub const MAX_RIM_SEGMENTS: usize = 12;
  pub struct RimSeg { pub start_deg: f32, pub end_deg: f32, pub state: State }
  pub fn rim_segments(sessions: &[Session]) -> Vec<RimSeg>;       // sessions arrive waiting-first
  pub fn fmt_ago(now: Option<i64>, since: i64) -> String;
  pub fn presence_for(m: &Model) -> PresenceKind;                // Alert / Thinking / Idle
  pub enum PresenceKind { Idle, Thinking, Alert }
  ```
  Screens in `app.slint`: `AppWindow` has `in property <[SessionRow]> rows`, `in property <[RimSegment]> rim`, `in property <Page> page` (`idle, list, question, detail`), `in property <bool> link`, question properties (`question-text`, `options`, `multi`, `selected`), `in property <string> detail-host, detail-project, detail-state, detail-since`, `in property <string> summary` and `in property <[string]> recent` (empty in this sub-project), and callbacks `option-tapped(int)`, `done-tapped()`, `decline-tapped()`, `row-tapped(int)`, `arc-tapped(int)`, `back-tapped()`, `avatar-tapped()`.

- [ ] **Step 1: Write failing unit tests** (Review Focus 2 and 5 included): `rim_zero_sessions_is_empty`, `rim_one_session_spans_354_degrees` (6 degree gap), `rim_four_sessions_are_equal_arcs_with_a_6_degree_gap`, `rim_caps_at_12_arcs_and_keeps_every_waiting_session` (13 sessions, 2 waiting: the 2 waiting have their own arcs and the last arc is a grey aggregate), `rim_with_40_sessions_stays_at_12`, `fmt_ago_clock_unset_is_dashes` (`None` gives `"--"`), `fmt_ago_units` (59 gives `59s`, 60 gives `1m`, 3600 gives `1h`, 86400 gives `1d`), `fmt_ago_future_since_is_zero_seconds`, `presence_alert_when_any_session_waiting`, `presence_thinking_when_working_and_none_waiting`, `presence_idle_otherwise`.
- [ ] **Step 2: Run `cargo test -p cylon-bot-ui`.** Expected: FAIL.
- [ ] **Step 3: Implement `view.rs`** (the clock is treated as unset when `now < 1735689600`, as `ui.c` does) and the four screens: home (avatar in the rim), session list, question takeover (answer buttons, Done for multi-select, a decline control), session detail (host, project, state, time, and the empty `summary` and `recent` areas that scroll by touch).
- [ ] **Step 4: Extend the preview to render each screen and state:** idle, list with 5 sessions (one waiting), question single, question multi, detail, a 13-session rim, and a unicode question.
- [ ] **Step 5: Run the tests, run `just board preview`, and open the PNGs.** Fix any clipped text on the round edge.
- [ ] **Step 6: Commit.** `git commit -m "feat(raider): add the slint screens and view logic"`.

### Task 9: Controller

**Files:**
- Create: `firmware/cylon-bot/ui/src/controller.rs`
- Modify: `firmware/cylon-bot/ui/src/lib.rs`
- Test: `firmware/cylon-bot/ui/src/controller.rs` (unit tests)

**Interfaces:**
- Consumes: Task 6's `Model`, Task 8's view functions and the `AppWindow` properties.
- Produces:
  ```rust
  pub trait Outbox { fn send(&self, json: String) -> bool; }       // false when not connected
  pub struct Controller<O: Outbox> { /* Model, AppWindow handle, outbox, selection state */ }
  impl<O: Outbox> Controller<O> {
      pub fn new(window: &AppWindow, outbox: O) -> Self;
      pub fn on_message(&mut self, json: &str);                     // network task, via invoke_from_event_loop
      pub fn set_link(&mut self, up: bool);
      pub fn tick(&mut self, now: Option<i64>);                     // refresh time-in-state text
      pub fn wants_chime(&mut self) -> bool;                        // true when waiting count rose, or a new ask id appeared
  }
  ```
  The window's callbacks (`option_tapped`, `done_tapped`, `decline_tapped`, `row_tapped`, `arc_tapped`, `back_tapped`, `avatar_tapped`) are wired in `new`.

- [ ] **Step 1: Write failing tests with a fake `Outbox` that records frames:** `single_select_option_sends_the_answer_once`, `double_tap_on_an_option_sends_one_answer` (Review Focus 4), `multi_select_toggles_then_done_sends_joined_labels`, `done_with_nothing_selected_sends_nothing`, `decline_sends_decline_and_hides_the_question`, `stale_selection_is_cleared_when_a_snapshot_drops_and_the_same_ask_returns` (Review Focus 3), `snapshot_while_question_open_goes_back_to_the_list_then_reopens`, `tap_on_a_row_opens_detail_and_back_returns_to_the_list`, `wants_chime_is_true_when_a_new_ask_appears_and_false_on_repeat`, `tick_with_unset_clock_shows_dashes` (Review Focus 5), `offline_link_flag_is_set_on_the_window`.
- [ ] **Step 2: Run the tests.** Expected: FAIL.
- [ ] **Step 3: Implement the controller.** Selection state is keyed by `(ask id, question index)` and reset whenever either changes. The answer message is built with `Model::answer` and sent through `Outbox::send`.
- [ ] **Step 4: Run the tests.** Expected: PASS.
- [ ] **Step 5: Commit.** `git commit -m "feat(raider): add the board controller"`.

### Task 10: Firmware app skeleton with the display

**Files:**
- Create: `firmware/cylon-bot/app/{Cargo.toml,rust-toolchain.toml,build.rs,sdkconfig.defaults,partitions.csv,.cargo/config.toml}`, `firmware/cylon-bot/app/components/board_display/*` (from Task 3), `firmware/cylon-bot/app/src/{main.rs,platform.rs,display.rs}`
- Modify: `just/board.just` (`build`, `flash`, `monitor`, `creds`), `firmware/cylon-bot/.gitignore`

**Interfaces:**
- Consumes: Task 3's `board_display.h`, Task 7 to 9's `cylon-bot-ui`.
- Produces: `app` builds from its own directory (a separate Cargo package outside the host workspace, depending on `cylon-bot-ui` and `cylon-bot-proto` by path) and shows the home screen with a demo model. `platform.rs`: `pub fn run(window: Rc<MinimalSoftwareWindow>) -> !` drives the Slint event loop, renders by line in 8-line batches through `display::draw`, feeds `bd_touch_read` into pointer events, and calls `slint::platform::update_timers_and_animations()`.

- [ ] **Step 1: Move the PSRAM, DMA-pool, Wi-Fi and mbedTLS lines from the C `sdkconfig.defaults` into `app/sdkconfig.defaults`** (the comments explaining them go with them), copy `partitions.csv`, and drop every LVGL line. Keep the old C tree untouched.
- [ ] **Step 2: Update `just board build`, `flash`, `monitor` and `creds`.** `build` runs `cargo build --release` in `app/`. `flash` and `monitor` use `espflash` with `partitions.csv`. `creds` writes `app/credentials.env` (gitignored) and no longer needs the `kconfig-seed.json` dance for the Rust build. The C firmware is built from `main` only until Task 14, so keep its recipes as `build-c` and `flash-c`.
- [ ] **Step 3: Write `main.rs`:** init the display, create the window, build a `Controller` over a no-op `Outbox`, feed it the `state.json` fixture (embedded with `include_str!`) and run the loop. Keep the 30 s heap report line.
- [ ] **Step 4: Build and flash.** Expected: the home screen with the rim and avatar shows, animates, and responds to a tap on an arc by opening a detail screen. Record frames per second and heap lines from the serial log.
- [ ] **Step 5: Commit.** `git commit -m "feat(raider): boot the rust firmware with the slint home screen"`.

### Task 11: Network task and wiring

**Files:**
- Create: `firmware/cylon-bot/app/src/net.rs`, `firmware/cylon-bot/app/src/config.rs`
- Modify: `firmware/cylon-bot/app/src/main.rs`, `firmware/cylon-bot/app/build.rs`
- Test: `firmware/cylon-bot/app/src/net.rs` (host-testable pure parts behind `#[cfg(test)]`, run with `--target x86_64-unknown-linux-gnu`)

**Interfaces:**
- Consumes: Task 9's `Controller` and `Outbox`.
- Produces:
  ```rust
  pub struct Config { ssid: &'static str, pass: &'static str, token: &'static str, url: &'static str, ntp: &'static str, dns: Option<&'static str> } // from build-time env, defaults: url "wss://cylon-bot.arsfeld.one/v1/board", ntp "pool.ntp.org"
  pub fn backoff_ms(attempt: u32) -> u32;     // 1000 doubling to a cap of 30000
  pub fn clock_is_set(unix_secs: i64) -> bool; // false before 2025-01-01
  pub struct Net;  impl Outbox for Net { fn send(&self, json: String) -> bool }
  pub fn start(cfg: Config, on_message: impl Fn(String) + Send + 'static, on_link: impl Fn(bool) + Send + 'static) -> Net;
  ```

- [ ] **Step 1: Write failing tests:** `backoff_doubles_from_one_second_to_a_cap_of_thirty`, `clock_is_set_rejects_before_2025_and_accepts_after`, `config_defaults_apply_when_url_and_ntp_unset`.
- [ ] **Step 2: Run them on the host target.** Expected: FAIL.
- [ ] **Step 3: Implement `net.rs`** from the probe's code: WPA2-or-better Wi-Fi, SNTP, connect only once the clock is set, websocket with the bearer header and the certificate bundle, optional DNS override, reconnect with `backoff_ms`, link callbacks. Messages hop to the UI thread with `slint::invoke_from_event_loop`. `send` returns false when disconnected.
- [ ] **Step 4: In `main.rs`, replace the demo with the real path:** `on_message` calls `Controller::on_message`, plays the chime when `wants_chime()` is true, and `on_link` calls `set_link`.
- [ ] **Step 5: Run the host tests, build, flash, and watch against the live bridge.** Expected: connects, the home screen shows the real sessions, and a test question from `cylon-bot-hook` appears on the board and can be answered.
- [ ] **Step 6: Commit.** `git commit -m "feat(raider): connect the rust firmware to the bridge"`.

### Task 12: Idle dim, wake, drift and heap

**Files:**
- Create: `firmware/cylon-bot/app/src/power.rs`
- Modify: `firmware/cylon-bot/app/src/main.rs`, `firmware/cylon-bot/ui/ui/app.slint` (drift offset property)
- Test: `firmware/cylon-bot/app/src/power.rs` (host tests)

**Interfaces:**
- Produces:
  ```rust
  pub struct Power { /* last_activity_ms, last_change_ms */ }
  impl Power { pub fn new() -> Self; pub fn touch(&mut self, now_ms: i64); pub fn model_changed(&mut self, now_ms: i64);
               pub fn awake(&self, now_ms: i64) -> bool;      // within AWAKE_MS of a touch or a model change
               pub fn brightness(&self, now_ms: i64) -> u8; } // BRIGHT_AWAKE or BRIGHT_IDLE
  pub fn drift_px(now_ms: i64) -> (i32, i32);                 // within +-4 px, changes slowly (about once a minute)
  ```

- [ ] **Step 1: Write failing tests:** `awake_for_30_seconds_after_a_touch`, `awake_for_30_seconds_after_a_model_change`, `idle_after_that_uses_brightness_8`, `awake_uses_brightness_70`, `drift_stays_within_four_pixels_over_a_day`.
- [ ] **Step 2: Run them.** Expected: FAIL.
- [ ] **Step 3: Implement `power.rs`, apply brightness through `bd_set_brightness` on change, and apply the drift as a Slint property on the avatar and rim.**
- [ ] **Step 4: Run the tests, build and flash.** Expected: screen dims after 30 s, wakes on touch and on a new question.
- [ ] **Step 5: Commit.** `git commit -m "feat(raider): dim, wake and drift the board display"`.

### Task 13: Device verification and parity

**Files:**
- Modify: `docs/superpowers/specs/2026-11-09-cylon-bot-rust-probe-findings.md` (append a "parity run" section)

- [ ] **Step 1: Run the parity checklist on the board against the live bridge** and tick each against the spec's Parity section: TLS to the bridge with the bundle, no connect before the clock, session list and time in state, takeover on a waiting question, single answer, multi-select with Done, decline, detail screen, chime, dim and wake, credentials from sops.
- [ ] **Step 2: Run the failure cases:** a wrong certificate (point `url` at a host with an untrusted cert, expect no connection and no crash), a blocked NTP server (expect no connection and the clock text `--`), Wi-Fi off and on (expect reconnect and the session list returns), and a bridge restart with a question open (expect the stale selection cleared). Record results.
- [ ] **Step 3: Soak for 30 minutes with a hook script producing a state change every 10 s.** Expected: internal free RAM from the 30 s heap lines does not trend down.
- [ ] **Step 4: Commit.** `git commit -m "docs(raider): record the rust firmware parity run"`. Anything that fails goes back to the owning task before Task 14.

### Task 14: Retire the C firmware and update docs

**Files:**
- Delete: `firmware/cylon-bot/main/`, `firmware/cylon-bot/components/board_proto/`, `firmware/cylon-bot/CMakeLists.txt`, `firmware/cylon-bot/dependencies.lock`, `firmware/cylon-bot/kconfig-seed.json`, `firmware/cylon-bot/sdkconfig`, `firmware/cylon-bot/sdkconfig.defaults`, `firmware/cylon-bot/sdkconfig.defaults.local`, `firmware/probe-rust/`
- Modify: `just/board.just` (remove `build-c`, `flash-c`, `test-c`, and the sdkconfig writing from `creds`), `CLAUDE.md` (the Cylon Bot section: firmware, tooling, traps), `modules/flake/dev.nix` (drop `cjson` from the firmware shell if nothing else uses it)

- [ ] **Step 1: Confirm Task 13 passed,** then delete the files above with `git rm`.
- [ ] **Step 2: Rewrite the Cylon Bot section of `CLAUDE.md`:** the new layout, `just board` recipes (including `preview`), the dev shell's Rust toolchain, the shared proto crate and fixtures rule, and the firmware traps that still apply (internal RAM, PSRAM settings, 2.4 GHz). Remove the LVGL and component-manager traps that no longer apply. Link the spec and the probe findings.
- [ ] **Step 3: Run `just board test`, `just board build`, `just board preview`.** Expected: all succeed from a clean checkout state.
- [ ] **Step 4: Commit.** `git commit -m "refactor(raider): retire the c board firmware"`.
