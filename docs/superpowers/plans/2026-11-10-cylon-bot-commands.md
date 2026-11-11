# Cylon Bot Command Arcs Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A swipe down from the top edge of the board's home screen opens three command arcs — VOL, LINK, PURGE —
leading to a volume page, a Wi-Fi/bridge status page, and a hold-to-purge page that starts a new Hermes session.

**Architecture:** Board side, the `ui` crate gains an edge-swipe gesture, three pages and a menu state in the
`Controller`; geometry is precomputed in Rust as tight-box `Path` models. The `app` crate wires gestures, the
volume buttons and Wi-Fi readings. Protocol 5 adds `new_session` / `session_reset`. Bridge side, Hermes' session id
becomes a persisted, resettable `SessionId`, and the voice pipeline speaks a fixed confirmation through the same
path reminders use.

**Tech Stack:** Rust (Slint software renderer on ESP-IDF; axum/tokio bridge), Slint markup, NixOS module.

**Spec:** `docs/superpowers/specs/2026-11-10-cylon-bot-commands-design.md`. Mockups:
https://claude.ai/artifact/QW7GQkZBWYxxF2Exe8euim (option B and the bottom row).

## Global Constraints

- Commit straight to `master`; no branches or worktrees. Commit only the files a task names (other sessions work in
  this tree): `git commit -- <paths>`.
- Conventional commits: firmware and proto `…(raider): …`, bridge and its NixOS module `…(galactica): …`. Never
  mention Claude.
- A new file is invisible to `nix build` until `git add`ed (`git add -N` is enough).
- `PROTOCOL_VERSION` becomes `5`. New messages: `{"t":"new_session","utterance":N}` (board → bridge) and
  `{"t":"session_reset","utterance":N}` (bridge → board).
- Spoken confirmation, exactly: `Memory purged. By your command.`
- New session id: `<base>-<unix seconds>`; persisted at `$STATE_DIRECTORY/hermes-session`.
- Edge band: a swipe down whose touch-down had `y < 60` (`EDGE_BAND_PX = 60`).
- Menu closes after `MENU_IDLE_MS = 10_000` with no touch. Purge hold `PURGE_HOLD_MS = 1500`. A purge with no
  `session_reset` after `RESET_WAIT_MS = 10_000` drops the mood to `idle`.
- Command arcs: centred at −44°, 0°, +44° from the top, 40° each, radius 200; arcs whose midpoint is within ±64° of
  the top are hidden while the menu is open.
- Volume page: 24 ticks over 240° (−120° to +120°). Purge ring: 36 ticks over 360°.
- Signal bars by RSSI: ≥ −55 → 4, ≥ −67 → 3, ≥ −75 → 2, ≥ −85 → 1, else 0.
- Damage regions: every animated or changing `Path` has its own tight box (`rim::arc_segment*`); no full-screen
  `Path` boxes. Fades use colour alpha, not `opacity`. Glyphs outside `ui/glyphs.slint` draw blank.
- Logs carry no session id, transcript or reply text: `voice: utt=<id> session reset`.
- Firmware UI tests: `nix develop .#firmware -c bash -c 'cd firmware/cylon-bot && cargo test -p cylon-bot-ui'`.
  Bridge tests: `nix develop -c bash -c 'cd packages/cylon-bot-bridge && cargo test'`. Proto: `nix build .#cylon-bot-proto`.

## Review Focus

1. **Swipe down that starts in the edge band but drifts diagonally** — expect neither menu nor volume change (the
   existing slope rule applies to `EdgeDown` too). Test in Task 4.
2. **Purge released at 1.4 s, then pressed again** — expect the ring to restart from zero, and no `new_session`.
   Test in Task 6 (controller ignores a confirm that Slint did not fire; Slint test drives the press/release).
3. **A question arriving while the menu or a command page is open** — expect the question to take over, and after
   it is answered the board returns to home with the menu closed, not to the command page. Test in Task 5.
4. **Bridge restart after a purge** — expect the new id to be read back, not `creature`. Test in Task 2.
5. **Purge while a reply is still speaking** — expect the reply to finish (or be cancelled by the tap as today) and
   the confirmation to speak after it, never interleaved audio. Test in Task 3.

---

### Task 1: Protocol 5 messages

**Files:**
- Modify: `packages/cylon-bot-proto/src/lib.rs` (`PROTOCOL_VERSION`, `BoardMsg`, `ClientMsg`, tests)
- Create: `packages/cylon-bot-bridge/tests/fixtures/board/session_reset.json`
- Modify: `packages/cylon-bot-bridge/tests/fixtures/board/hello.json` (version 5)
- Modify: `packages/cylon-bot-bridge/tests/wire.rs`

**Interfaces:**
- Produces: `BoardMsg::SessionReset { utterance: u32 }`, `ClientMsg::NewSession { utterance: u32 }`,
  `PROTOCOL_VERSION == 5`.

- [ ] **Step 1: Write failing tests.** In the proto tests, add `(ClientMsg::NewSession { utterance: 3 }, "new_session")`
  to the existing client-message table, and a `session_reset_fixture_round_trips` test parsing
  `session_reset.json` (`{"t":"session_reset","utterance":7}`) to `BoardMsg::SessionReset { utterance: 7 }` and
  serialising back to the same JSON. In `wire.rs`, `session_reset_matches_the_firmware_fixture`.
- [ ] **Step 2: Run** `nix build .#cylon-bot-proto` — expect a compile failure naming `NewSession`.
- [ ] **Step 3: Implement** the two variants (before `Unknown` in `BoardMsg`), bump `PROTOCOL_VERSION` to 5 and
  `hello.json`'s version, `git add -N` the fixture.
- [ ] **Step 4: Run** the proto build and the bridge's `cargo test --test wire` — expect PASS. The bridge must still
  compile: `ClientMsg::NewSession` is ignored there until Task 3 (the `_ => {}` arms already cover it; add one in
  `board.rs` if its match is exhaustive).
- [ ] **Step 5: Commit** `feat(raider): add the board's new_session and session_reset messages (protocol 5)`.

### Task 2: Resettable, persisted Hermes session

**Files:**
- Create: `packages/cylon-bot-bridge/src/voice/session.rs` (register in `src/voice/mod.rs`)
- Modify: `packages/cylon-bot-bridge/src/voice/backends.rs` (`HermesHttp`, `Brain`)
- Modify: `packages/cylon-bot-bridge/src/main.rs` (`voice()`, `open_timers()`)
- Modify: `modules/hosts/galactica/services/cylon-bot.nix` (`serviceConfig.StateDirectory = "cylon-bot";`)
- Test: `packages/cylon-bot-bridge/tests/session.rs` (new), `tests/backends.rs`

**Interfaces:**
- Produces:
  - `pub struct SessionId` with `pub fn load(base: String, path: Option<PathBuf>) -> SessionId`,
    `pub fn current(&self) -> String`, `pub fn reset(&self, now_secs: i64) -> String` (interior `Mutex`; writes the
    file, logs `voice: session id not saved: <io error kind>` on failure and keeps the new id in memory).
  - `Brain::new_session(&self)` with a default no-op body, so existing fakes compile; `HermesHttp` overrides it with
    `self.session.reset(now)`.
  - `HermesHttp::new(base_url: String, api_key: String, session: Arc<SessionId>)`.
- Note: `cylon-bot` has no `StateDirectory` today, so `open_timers()` has been running in memory only; this task
  fixes that too. Factor the `$STATE_DIRECTORY` lookup into `fn state_file(name: &str) -> Option<PathBuf>` used by both.

- [ ] **Step 1: Write failing tests** in `tests/session.rs`:
  - `load_without_a_file_uses_the_base`: `current() == "creature"`.
  - `reset_mints_base_dash_seconds_and_writes_it`: `reset(1794326900) == "creature-1794326900"`, file content equals it.
  - `a_new_instance_reads_the_saved_id` (Review Focus 4).
  - `an_empty_or_blank_file_falls_back_to_the_base`.
  - `an_unwritable_path_still_resets_in_memory` (path inside a nonexistent directory).
  In `tests/backends.rs`: `hermes_uses_the_new_session_after_reset` — after `new_session()`, the next `/v1/runs`
  body's `session_id` starts with `creature-` and differs from `creature`; update `hermes_sends_bearer_key_and_session_id`
  for the new constructor.
- [ ] **Step 2: Run** `cargo test --test session --test backends` — expect compile failure.
- [ ] **Step 3: Implement** `session.rs`, the `Brain` default method, `HermesHttp`'s `Arc<SessionId>` (read
  `current()` at the start of each `ask`, so an in-flight run keeps its id), and the `main.rs` wiring with
  `state_file("hermes-session")`.
- [ ] **Step 4: Run** all bridge tests — expect PASS. Build galactica:
  `nix build .#nixosConfigurations.galactica.config.system.build.toplevel` (one host, niced).
- [ ] **Step 5: Commit** `feat(galactica): keep the creature's Hermes session id resettable and on disk`.

### Task 3: `new_session` in the voice pipeline

**Files:**
- Modify: `packages/cylon-bot-bridge/src/voice/pipeline.rs`
- Modify: `packages/cylon-bot-bridge/src/board.rs` (route `ClientMsg::NewSession` to the voice `Conn` alongside
  `VoiceStart`/`VoiceEnd`/`Cancel`)
- Test: `packages/cylon-bot-bridge/tests/pipeline.rs`

**Interfaces:**
- Consumes: `Brain::new_session` (Task 2), `BoardMsg::SessionReset` / `ClientMsg::NewSession` (Task 1).
- Produces: `pub const PURGE_LINE: &str = "Memory purged. By your command.";`; the reminder queue generalised to
  spoken lines: `reminders: VecDeque<(u32, Due)>` becomes `lines: VecDeque<(u32, String)>`, and `run_reminder`
  becomes `run_line(backends, out, timeout, id, text: String, speaking, after)` (reminders queue
  `spoken_reminder(&due)`). Rate check factored into `fn admit(&mut self) -> bool`, used by `VoiceStart` and
  `NewSession`.

Behaviour of `ClientMsg::NewSession { utterance }`:
- Over the per-minute limit: `Creature { Idle }` only.
- No backends: `SessionReset { utterance }`, then `Creature { Offline }`.
- Otherwise: `brain.new_session()`, log `voice: utt=<id> session reset`, `SessionReset { utterance }` via `control`,
  then queue `(utterance, PURGE_LINE)` and `tick()`. It does not stop a running reply; `tick` starts the line once
  nothing is running (Review Focus 5).

- [ ] **Step 1: Write failing tests** (use the existing `rig` helpers; give `FakeBrain` a `resets: AtomicUsize`
  counted by `new_session`):
  - `new_session_resets_acks_and_speaks`: log is `SessionReset{u}`, `Creature{Speaking}`, `SpeakStart{u,…}`, audio,
    `SpeakEnd{u}`, `Creature{Idle}`; `resets == 1`; TTS received `PURGE_LINE`.
  - `new_session_without_backends_acks_and_reports_offline`.
  - `new_session_over_the_limit_is_refused_with_idle`: 10 `VoiceStart`s first, then no `SessionReset`, `resets == 0`.
  - `new_session_during_a_reply_speaks_after_it`: `assert_balanced`, and the second `SpeakStart` follows the first
    `SpeakEnd`.
  - Existing reminder tests keep passing unchanged.
- [ ] **Step 2: Run** `cargo test --test pipeline` — expect FAIL.
- [ ] **Step 3: Implement** as described.
- [ ] **Step 4: Run** all bridge tests — expect PASS.
- [ ] **Step 5: Commit** `feat(galactica): start a new creature session on the board's request and say so`.

### Task 4: Edge swipe gesture

**Files:**
- Modify: `firmware/cylon-bot/ui/src/touch.rs`
- Modify: `firmware/cylon-bot/app/src/platform.rs` (`static EDGE_DOWN: AtomicBool`, `pub fn take_edge_down() -> bool`)

**Interfaces:**
- Produces: `pub const EDGE_BAND_PX: f32 = 60.0;`, `Gesture::EdgeDown` (only while vertical swipes are on, start
  `y < EDGE_BAND_PX`, otherwise identical to `SwipeDown`'s recognition); `platform::take_edge_down() -> bool`.
  `take_swipe_vertical()` never reports an `EdgeDown`.

- [ ] **Step 1: Write failing tests** in `touch.rs`, using the existing `drag` helper:
  - `a_swipe_down_from_the_top_band_is_an_edge_swipe`: `drag((233, 30), (233, 200))` → `EdgeDown`.
  - `a_swipe_down_from_lower_is_still_quieter`: `drag((233, 120), (233, 300))` → `SwipeDown`.
  - `edge_swipes_need_vertical_swipes_on`: off → `None`.
  - `a_diagonal_drag_from_the_band_is_nothing` (Review Focus 1): `drag((200, 30), (330, 160))` → `None`.
- [ ] **Step 2: Run** the UI tests — expect FAIL.
- [ ] **Step 3: Implement** (keep the swipe's start position from touch-down) and the platform flag, set where
  `Gesture::SwipeDown` is handled today.
- [ ] **Step 4: Run** the UI tests — expect PASS; `just board build` compiles.
- [ ] **Step 5: Commit** `feat(raider): recognise a swipe down from the board's top edge`.

### Task 5: Command arcs on home

**Files:**
- Modify: `firmware/cylon-bot/ui/src/rim.rs` — `pub fn arc_segment_at(start_deg, end_deg, radius: f32, half_stroke: f32, state) -> RimSegment`; `arc_segment` delegates with `RADIUS`, 7.0.
- Modify: `firmware/cylon-bot/ui/src/view.rs` — `pub enum Command { Volume, Link, Purge }`,
  `pub fn command_at(deg: f32) -> Option<Command>` (−64..−24 Volume, −20..20 Link, 24..64 Purge, after
  normalising to −180..180), `pub fn command_segments() -> Vec<RimSegment>` (3 arcs, radius 200, half-stroke 26),
  `rim_models(sessions, menu_open: bool)` dropping arcs whose midpoint is within ±64°.
- Modify: `firmware/cylon-bot/ui/src/controller.rs` — `menu_open: bool`, `menu_touched_ms: u64`; `Nav` gains
  `Volume`, `Link`, `Purge`.
- Modify: `firmware/cylon-bot/ui/ui/theme.slint` (`Page` gains `volume`, `link`, `purge`),
  `ui/app.slint` (`in property <bool> menu-open`, `in property <[RimSegment]> commands`, `callback command-tapped(int)`),
  `ui/home.slint` (draws `commands` as metal arcs — `#5b606b` outline under a `#15171c` fill, PURGE outlined
  `#ff2a1a` and drawn at reduced alpha while `!link` — with icons and labels from the mockup, only `if root.menu-open`), placeholder `VolumePage`,
  `LinkPage`, `PurgePage` components showing their title only (filled by Tasks 6–7).
- Test: `firmware/cylon-bot/ui/tests/controller.rs`, view unit tests.

**Interfaces:**
- Produces on `Controller`: `pub fn open_menu(&self)`, `pub fn menu_open(&self) -> bool`, `pub fn note_touch(&self)`
  (resets the idle clock). Rim taps while the menu is open go to `command_at` instead of `arc_index_at`; a hit
  sets `Nav` to the page and closes the menu. Closing: `back_tapped` on home, `avatar_tapped`, `tick_at` after
  `MENU_IDLE_MS` since the last `note_touch`/`open_menu`, and any question taking over. `back_tapped` from
  `Volume`/`Link`/`Purge` goes to `Home`.

- [ ] **Step 1: Write failing tests:**
  - view: `command_at` boundaries (−44 → Volume, 0 → Link, 44 → Purge, 22 → None, 90 → None);
    `rim_models(.., true)` hides a top arc and keeps a bottom one; each `command_segments()` box lies inside 466×466
    and is under 200 px wide.
  - controller: `edge_menu_opens_and_a_rim_tap_opens_its_page` (tap at the Link arc → `Page::Link`, menu closed);
    `the_menu_closes_after_ten_idle_seconds`; `a_touch_keeps_the_menu_open`; `the_avatar_closes_the_menu`;
    `back_from_a_command_page_returns_home`; `a_question_closes_the_menu_and_answering_returns_home` (Review Focus 3).
- [ ] **Step 2: Run** the UI tests — expect FAIL.
- [ ] **Step 3: Implement.** `refresh()` sets `menu-open` and `commands` (built once in `Controller::new`).
- [ ] **Step 4: Run** the UI tests — expect PASS. Add a `home-menu` render to `examples/preview.rs`, run
  `just board preview`, and look at `preview/home-menu.png`: three arcs at the top, head unmoved, no top session arcs.
- [ ] **Step 5: Commit** `feat(raider): open command arcs from the board's top edge`.

### Task 6: Volume and purge pages

**Files:**
- Modify: `firmware/cylon-bot/ui/src/rim.rs` — `pub fn ticks(from_deg: f32, to_deg: f32, n: usize, r_in: f32, r_out: f32) -> Vec<Tick>` (each a radial line `Path` with its own even-aligned box).
- Modify: `firmware/cylon-bot/ui/ui/theme.slint` — `export struct Tick { x: length, y: length, width: length, height: length, commands: string }`.
- Create: `firmware/cylon-bot/ui/ui/volume.slint`, `firmware/cylon-bot/ui/ui/purge.slint` (replace Task 5's placeholders).
- Modify: `ui/app.slint`, `ui/home.slint` (the swipe pill becomes a short row of red ticks), `src/controller.rs`.
- Test: `ui/tests/controller.rs`, `ui/tests/render.rs`.

**Interfaces:**
- Slint: `in property <[Tick]> volume-ticks` (24, −120..120, r 195..221), `in property <[Tick]> ring-ticks` (36,
  0..360 minus one step, r 200..222); a tick is lit when `index < round(count * fraction)`, computed in Slint
  (`#ff2a1a`, the last lit `#ffb4a0`, unlit `#1f2128`). `callback volume-step(bool)`, `callback purge-confirmed()`.
  The purge page owns `property <float> progress`, advanced by a 33 ms `Timer` while its button's `TouchArea.pressed`
  and reset to 0 on release; reaching 1 (after `PURGE_HOLD_MS`) calls `purge-confirmed()` once. Its button is
  disabled-looking and inert while `!link`.
- Controller: `pub fn take_volume_step(&self) -> Option<bool>` (a − or + tap waiting for the app); on
  `purge-confirmed`: if linked and no reset pending, next utterance id, send `ClientMsg::NewSession`, mood
  `Thinking`, `Nav::Home`, remember `(id, time)`; `BoardMsg::SessionReset` with that id clears it; `tick_at` after
  `RESET_WAIT_MS` without it sets mood `Idle`.
- This replaces the spec's "four quarter arcs" for the ring: 36 tick boxes give the same repaint bound with one
  geometry helper shared with the volume page. Update the spec's Purge paragraph in this task's commit.

- [ ] **Step 1: Write failing tests:**
  - rim: `ticks(-120.0, 120.0, 24, 195.0, 221.0)` has 24 entries, first and last symmetric about x = 233, every box
    under 40×40.
  - controller: `volume_buttons_queue_steps` (`invoke_volume_step(true)` → `take_volume_step() == Some(true)`, then
    `None`); `purge_sends_new_session_once_and_goes_home`; `purge_is_ignored_while_unlinked`;
    `session_reset_clears_the_wait`; `no_session_reset_drops_to_idle_after_ten_seconds`.
  - render (headless, real pointer events): `holding_purge_for_1_5_s_confirms` and
    `releasing_purge_early_restarts_the_ring` (press 1400 ms, release, press 1400 ms → no `new_session`; Review Focus 2).
- [ ] **Step 2: Run** the UI tests — expect FAIL.
- [ ] **Step 3: Implement** the pages after the mockups (big level number in Sora, "AUDIO LEVEL", metal − / +
  buttons; small head, "PURGE MEMORY", one line of explanation, "HOLD", "RELEASE TO ABORT"). Check every new
  literal character is in `ui/glyphs.slint`.
- [ ] **Step 4: Run** the UI tests — expect PASS. Add `volume` and `purge` (at 65 % progress) renders to the preview,
  run `just board preview`, and look at both PNGs.
- [ ] **Step 5: Commit** `feat(raider): add the board's volume and purge pages`.

### Task 7: Link page and app wiring

**Files:**
- Create: `firmware/cylon-bot/ui/ui/link.slint` (replaces the placeholder)
- Modify: `firmware/cylon-bot/ui/src/view.rs` — `pub fn signal_bars(rssi: i32) -> i32`, `pub fn fmt_uptime(secs: u64) -> String` (`"42s"`, `"7m"`, `"3h 12m"`, `"2d 4h"`)
- Modify: `firmware/cylon-bot/ui/ui/theme.slint` — `export struct LinkInfo { rssi: int, bars: int, ssid: string, address: string, uptime: string }`; `app.slint` `in property <LinkInfo> link-info`
- Create: `firmware/cylon-bot/app/src/wifi_info.rs` — `pub struct WifiInfo { pub rssi: i8, pub ssid: String, pub ip: Option<Ipv4Addr> }`, `pub fn read() -> Option<WifiInfo>` (`esp_wifi_sta_get_ap_info`; the `WIFI_STA_DEF` netif's `esp_netif_get_ip_info`); `None` when not associated
- Modify: `firmware/cylon-bot/app/src/main.rs`

**Interfaces:**
- Consumes: `platform::take_edge_down` (Task 4), `Controller::{open_menu, menu_open, note_touch, take_volume_step}`
  (Tasks 5–6).
- main loop changes: `take_touch()` also calls `controller.note_touch()`; `take_edge_down()` on home →
  `controller.open_menu()`; a vertical swipe while the menu is open closes it on up and does nothing on down; the
  existing swipe-volume block becomes `fn step_volume(louder, saved, ui, &mut abandoned, &mut volume_hide)`, called
  from the swipe and from `take_volume_step()` (the page shows the level itself, so the pill is skipped there);
  while `ui.get_page() == Page::Link`, every 2 s set `link-info` from `wifi_info::read()`, `view::signal_bars`,
  `view::fmt_uptime(boot.elapsed())` (no association: bars 0, ssid `"--"`, address `"--"`).

- [ ] **Step 1: Write failing tests:** `signal_bars` at −50, −55, −56, −67, −75, −85, −86, −100 → 4, 4, 3, 3, 2, 1, 0, 0;
  `fmt_uptime` at 42, 420, 11_520, 187_200.
- [ ] **Step 2: Run** the UI tests — expect FAIL.
- [ ] **Step 3: Implement** the helpers, `link.slint` after the mockup (four arcs lit by `bars`, RSSI with "dBm",
  rows NETWORK / ADDRESS / BRIDGE / VOICE / UPTIME; BRIDGE and VOICE green when up, muted when down, from the
  existing `link` and `voice-available` properties), `wifi_info.rs` and the main loop.
- [ ] **Step 4: Run** the UI tests — expect PASS; add a `link` render to the preview and look at it; `just board build`.
- [ ] **Step 5: Commit** `feat(raider): show Wi-Fi and bridge status on the board and wire the command pages`.

### Task 8: Docs, deploy and board check

**Files:**
- Modify: `CLAUDE.md` ("Cylon Bot" section: the command arcs, protocol 5, `$STATE_DIRECTORY/hermes-session`,
  that timers now persist, and the deploy order)

- [ ] **Step 1:** Update `CLAUDE.md`; commit `docs(raider): describe the board's command arcs`.
- [ ] **Step 2:** `just deploy galactica`; check `systemctl status cylon-bot` is active and
  `/var/lib/cylon-bot` exists.
- [ ] **Step 3:** `just board build && just board flash`, then `just board monitor` and verify on the board:
  edge swipe opens the arcs and lower swipes still change volume; − / + chime at each level and the level survives a
  reboot; the Link page's RSSI is within a few dB of what raider reports for the same network
  (`nmcli -f IN-USE,SSID,SIGNAL dev wifi`); a purge speaks the line and "what did I just ask you?" gets no memory of
  the previous exchange; the journal shows `voice: utt=<id> session reset`.
- [ ] **Step 4:** Report what was and was not verified on the board.
