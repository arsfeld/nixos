# Claude Board: Rust and Slint rewrite

Date: 2026-11-09. Status: draft for review.

## Why

The board firmware (`firmware/claude-board`) is about 1,100 lines of C on ESP-IDF 5.5.4 with LVGL 9.4. It
works, but it looks like a list of grey cards and it only answers questions. The goal is a board that
feels like an assistant (Jarvis-like), with Claude Code management as one feature among others, and that
can show what a session is actually doing instead of only its state.

That goal is larger than one change, so it is split. This spec covers only the first part.

| # | Sub-project | Depends on | Spec |
|---|---|---|---|
| 1 | Rust and Slint firmware, new look, drawn avatar, parity with today | none | this document |
| 2 | Reading session output (bridge, hooks, session detail screen) | none | later |
| 3 | Assistant core: wake word, microphone, speech to text, LLM, speech out, start a session in a project | 1 | later |
| 4 | Upgrade the avatar to streamed real-time 3D | 1, ideally 3 | later, after a frame-rate probe |

Order: 1, then 2 and 3 in either order, then 4.

## Decisions already made

- **Language and UI toolkit:** Rust with Slint.
- **Base:** `esp-idf-svc` on ESP-IDF, not bare-metal `esp-hal`. Waveshare's CO5300 display and CST9217 touch
  init stays in C and is reused. No Rust driver exists for either chip.
- **Look:** direction A ("Instrument") from the mockups at
  https://claude.ai/artifact/NJ6PUSJkS1bXuoCdUDniV4: a ring around the screen with one arc per session,
  with the avatar in the middle. Moves toward a HUD feel.
- **Avatar:** drawn on the board from vector shapes and gradients, animated locally. Not 3D now. A streamed
  3D avatar can replace it later through one seam (see Seams).
- **Licence:** Slint under GPLv3. The repository is public and personal, so this is acceptable. Slint's
  royalty-free licence excludes embedded use. Re-check the terms when upgrading Slint.

## Scope of this spec (sub-project 1)

In scope:
- A shared Rust protocol crate used by both the bridge and the firmware.
- A Rust firmware crate with Slint UI, replacing the C and LVGL code.
- A small C component that keeps the BSP's panel and touch init.
- The new look: rim gauge, `Presence` avatar, session list, question screen, session detail screen.
- Every feature of the current firmware, with the same behaviour.
- Toolchain packaging, `just board` recipes and host-side tests.

Out of scope: session output text, voice, wake word, audio capture, real 3D, starting sessions from the
board. The seams for them are defined below but not built.

## Parity: what must keep working

From today's firmware: a websocket to the bridge over TLS with the full certificate bundle, no connection
until the clock is set by NTP, the session list with "time in state", a takeover screen for a waiting
question, single and multi-select answers with Done, decline, a session detail screen reached by tapping
a card, the chime when something starts waiting, the idle dim and wake behaviour (`AWAKE_MS`, brightness
levels), and the Wi-Fi and token credentials compiled in from `sdkconfig.defaults.local`.

## Architecture

### Shared protocol crate

A new crate, `packages/claude-board-proto`, holds the wire types with serde. The bridge
(`packages/claude-board-bridge`) and the firmware both depend on it. It replaces `board_proto` in C and the
hand-written parsing on each side. It builds for the host and for the ESP target, so it is `no_std`-friendly
where cheap and otherwise uses `alloc`.

The fixtures in `packages/claude-board-bridge/tests/fixtures/board/*.json` stay as the contract. The
bridge's `tests/wire.rs` keeps pinning output to them, and the proto crate parses every fixture in its own
tests. The firmware no longer carries a second parser, so the two sides cannot disagree about a field.

The protocol gains a version field in the hello exchange and tolerates unknown fields and unknown message
types, so later sub-projects can add messages without breaking older boards.

### Firmware crate

`firmware/claude-board` becomes a Rust crate on `esp-idf-svc` (std), still built on ESP-IDF 5.5.4.
- Wi-Fi, SNTP, the mbedTLS certificate bundle and the websocket client come from `esp-idf-svc`.
- `sdkconfig.defaults` is kept for the PSRAM, DMA-pool and Wi-Fi/mbedTLS-in-PSRAM tuning. The LVGL options
  are removed.
- Two tasks: a network task and a UI task, joined by a channel. Incoming protocol messages update a model,
  and the model drives Slint properties. User actions travel back over the same channel to the network task.
- Rust owns state and callbacks. Screens, theme and animation live in `.slint` files.

### C component

A small C component, `components/board_display`, keeps the Waveshare BSP's CO5300 (QSPI) and CST9217 (I2C)
initialisation and the brightness control. It exposes through a plain C header and Rust FFI:
- push a rectangular pixel region to the panel,
- read the latest touch event,
- set brightness,
- (reserved for sub-project 3) open the audio codec and microphone.

LVGL and `ui.c`, `net.c`, `chime.c`, `theme.h` and the C protocol core are removed once parity is reached.

### Rendering

Slint's software renderer draws line by line into a small buffer in internal RAM, and each line batch is
pushed to the panel through the C component. This replaces the 46 KB strips the BSP draws from PSRAM and
should lower internal-RAM pressure. This is an assumption to check in the probe, since internal RAM is the
scarce resource on this board.

## UI

### Navigation

- **Home:** the avatar in the centre of a ring. The ring has one arc per session in that session's state
  colour (blue working, amber waiting, green done, red error, grey idle). The waiting arc pulses.
- **Tap an arc:** open that session's detail screen.
- **Tap the avatar:** open the session list.
- **A waiting question** takes over the screen with the question and its answer buttons, as today.
- **Burn-in and power:** the avatar drifts a few pixels over time, and the idle dim from `AWAKE_MS` stays.

### `Presence` component

One reusable Slint component draws the avatar from paths, rings and radial gradients.
- Inputs: `state` (idle, listening, thinking, speaking, alert) and `level` (0 to 1, audio amplitude).
- All animation derives from those two inputs.
- In this sub-project `state` follows session events (a waiting question maps to alert, otherwise idle,
  with working sessions giving a calm "thinking" motion) and `level` is a demo value.
- Later, sub-project 3 sets `state` from the assistant and `level` from the microphone and speaker.

### Session detail

The detail screen gets `summary` (text) and `recent` (list of lines) properties now. In this sub-project it
shows only what the protocol carries today: host, project, state and time in state. Sub-project 2 fills
the two properties without changing the screen. The text area scrolls by touch.

### Fonts

Subsetted TTFs are embedded: Sora for display text and JetBrains Mono for data, both under open licences.
This removes the current missing-glyph boxes for accents. Binary size is measured in the probe.

## Seams for later sub-projects

- **Session output (2):** a new `session_output` message in the protocol crate. The hook client uploads
  transcript excerpts from each host, because the bridge on galactica cannot read other hosts' files. The
  bridge summarises, and the board receives `summary` and `recent`.
- **Assistant (3):** the websocket can carry binary frames, and the hello exchange advertises capabilities.
  The C component owns the audio codec, and the chime moves onto it. Wake word runs on the board using
  Espressif's ESP-SR. Speech to text, the LLM and text to speech run on the bridge side.
- **Streamed 3D avatar (4):** `Presence` gets an optional `frame` image property. A streamed avatar sets it
  and hides the drawn layers. Nothing else changes.

## Build and tooling

- The Xtensa Rust toolchain (Espressif's rustc fork) is packaged in the Nix dev shell next to the existing
  `nixpkgs-esp-dev` ESP-IDF setup. The flake-update caveat in `CLAUDE.md` applies: a weekly update may move
  `nixpkgs-esp-dev`, and the Rust toolchain pin must be reviewed with it.
- `just board` keeps its recipes: `backup`, `restore`, `creds`, `build`, `flash`, `monitor`, `test`.
  `test` runs the proto crate tests on the host. A new `just board preview` renders screens to PNG on the
  host with Slint's software renderer.
- The Claude Board section of `CLAUDE.md` is updated when the firmware moves.

## Testing

- **Protocol:** host tests parse and re-emit every fixture, plus property-style tests for unknown fields and
  versions, under the sanitizers the C tests used where they still apply.
- **UI:** the host preview renders each screen and state to PNG, so layout is reviewed without flashing.
  The serial-snapshot and self-test Kconfig options are retired. If a self-test of the on-device UI is
  still wanted, the plan decides how.
- **Device:** each milestone is flashed and checked against the live bridge, including the bad-certificate
  and blocked-NTP cases that the current Kconfig options allow.

## Risks and the first probe

The plan starts with a throwaway probe, labelled as such, answering these before any real work:
1. Does `esp-idf-sys` build against ESP-IDF 5.5.4 here, and does Wi-Fi, TLS and the websocket client work
   from Rust?
2. Does Slint's software renderer reach an acceptable frame rate and fit in internal RAM on this panel,
   with the existing PSRAM and DMA settings?
3. Can the Xtensa Rust toolchain be packaged reproducibly in the Nix dev shell?
4. What is the binary size with the embedded fonts?

If 1 or 2 fails, the fallback is to keep LVGL for the toolkit and still move the protocol and network
layers to Rust. That decision is made after the probe, not before.

Other risks: Slint and `esp-idf-svc` release cadence versus the weekly flake update; the C component's FFI
boundary is small but runs under FreeRTOS, so ownership of the touch and pixel buffers must be explicit.

## Open items for the plan

- The exact set of Slint animation primitives used by `Presence`, chosen against the probe's frame rate.
- Whether the drift and dim behaviour live in Rust or in Slint timers.
- Where the host preview tool lives in the repo.
