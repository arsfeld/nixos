# Cylon Bot Rust firmware: probe findings

Date: 2026-11-09. Source: `firmware/probe-rust/`, a throwaway crate that was deleted in Task 14 of
`docs/superpowers/plans/2026-11-09-cylon-bot-rust.md` (it is in git history: `git log --diff-filter=D -- firmware/probe-rust`);
its README's findings are folded into this document and into the `CLAUDE.md` traps list.
Spec: `docs/superpowers/specs/2026-11-09-cylon-bot-rust-design.md`.

## Verdict

**Go**, with changes to the plan's later tasks listed at the end. All four spec questions passed, and the
gates proposed in the plan passed with margin. Three things were not checked by eye and need a glance at the
board before the UI work depends on them.

## The spec's four questions

| # | Question | Answer |
|---|---|---|
| 1 | Does `esp-idf-sys` build against ESP-IDF 5.5.4, and do Wi-Fi, TLS and the websocket work from Rust? | **Yes.** `esp-idf-sys` 0.38.1, `esp-idf-svc` 0.53.0, `esp-idf-hal` 0.47.0 build against the nix ESP-IDF v5.5.4 with no downgrade. The board joined Wi-Fi (WPA3-SAE) in about 5 s, set its clock 1.8 s later, validated the certificate bundle and received the live bridge's `state` frame. |
| 2 | Does Slint's software renderer reach an acceptable frame rate and fit in internal RAM? | **Yes**, once damage regions are right. 28 to 29 fps with the rim pulse and centre animating together, 36 fps centre only, 59 fps rim only. About 110 KB of internal RAM free with Wi-Fi, TLS, the websocket and the display all running (the C firmware has about 118 KB with no Rust). |
| 3 | Can the Xtensa Rust toolchain be packaged reproducibly in the Nix dev shell? | **Yes.** `esp-rs-nix`'s `package.nix` (non-flake input, fetched by fixed hash) plus `espflash`, `ldproxy` and `libclang` from nixpkgs. `nix develop .#firmware` selects it with `RUSTUP_TOOLCHAIN`. |
| 4 | What is the binary size with embedded fonts? | The whole probe image is **1.89 MB** of the 6 MB app partition. The probe embedded one font (Sora, 84 KB TTF), but only for a few static strings; glyph cost for the real UI, with several sizes and dynamic text, is still to measure in Task 7. |
| + | Can the Waveshare BSP be used without LVGL? | **Not as a package**: it drags in LVGL, and the component manager fails inside `esp-idf-sys` (`MissingKconfigError: LV_USE_FREETYPE`). The needed code (pins, CO5300 QSPI init, brightness, CST9217 touch, ES8311 speaker) is carried in our own `board_display` component instead. |

## Gates proposed in the plan

| Gate | Result |
|---|---|
| At least 24 fps sustained on the probe scene | **Passed**: 28 to 29 fps for the busiest scene. |
| At least 80 KB internal RAM free with Wi-Fi and TLS up | **Passed**: about 110 KB with the display and Slint on top. |
| ESP-IDF 5.5.4 builds (or the version that was needed) | **Passed**, 5.5.4, unchanged. |
| Toolchain reproducible from `nix develop .#firmware` | **Passed.** |

## Not verified by eye (needs a look at the board)

1. **Colour order.** The probe shows red, green and blue bars for 6 s after boot, then the animated scene. The
   code swaps bytes to the panel's order; if red looks blue, flip `SWAP_BYTES`.
2. **The 80 MHz panel clock.** The BSP default is 40 MHz. 80 MHz gives a 17 ms full-frame push instead of
   27 ms, but the panel's pins go through the GPIO matrix, which may not tolerate it. Look for noise or
   tearing; if there is any, set `LCD_PCLK_HZ` back to 40 MHz (a costlier but still passing 12 ms to 20 ms
   push).
3. **Touch and the chime.** The touch controller initialises and is polled, but nothing was tapped during the
   run. The chime path was moved unchanged and not played.

## What the probe changes in the plan

- **Slint build.** No `std` feature; `software-renderer-path`; a local one-line patch to `i-slint-core`
  (`scripts/vendor-slint-core.sh`, gitignored `vendor/`). Task 7 carries the script into the `ui` crate and the
  dev shell gains `fontconfig` for the Slint compiler on the host.
- **Rim and Presence are shaped by what renders** (Tasks 7 and 8). Every rim arc is its own `Path` with a
  tight bounding box, since a `Path` with an animated property repaints its whole box each frame, hidden or not;
  hidden animated items are created with `if`. A rounded rectangle cannot hold a gradient and a gradient
  `Path` fill renders flat, so the avatar's glow is a pre-rendered tinted sprite used at native size
  (scaling it costs about 20 ms per frame).
- **`board_display` API** (Task 10) is the probe's: non-blocking `bd_draw` of up to 16 even-aligned rows,
  `bd_wait`, and an 80 MHz pixel clock pending the check above. The plan's blocking `bd_draw` was 3 times
  slower.
- **Flashing** (Task 10) passes the partition table to `espflash` at flash time, because `esp-idf-sys` ignores
  `CONFIG_PARTITION_TABLE_*`. After editing the C component, `cargo clean -p esp-idf-sys --release` is
  required; `just board build` should do it when the component's files are newer than the last build.
- **I2C.** `CONFIG_I2C_SKIP_LEGACY_CONFLICT_CHECK=y` is required.
- **Fonts** (Task 7): check on the host how the software renderer embeds glyphs (static strings versus the
  accents and other characters that arrive at run time in session names), before committing to the font
  plan.

## Parity run (Task 13)

Run on the board against the live bridge, with the firmware as built from `firmware/cylon-bot/app`. "Host" means
covered by the host test suites (`cylon-bot-ui`: 41 unit, 19 controller, 9 render, 10 touch with real pointer
events through the real window, 6 wheel; `cylon-bot-proto`: 27; the bridge: 67), not tried on the glass.

| Parity item | Result |
|---|---|
| TLS to the bridge with the certificate bundle | **Verified on the board.** Joins Wi-Fi in about 6 s, connects at about 8.5 s, receives the `state` frame. |
| Server certificate always validated | **Verified.** Pointed at a host with a self-signed certificate (dummy token): "No matching trusted root certificate found", no connection, retries with backoff. |
| No connection before the clock is set | **Verified.** With the clock cleared and an unreachable NTP server: "clock not set; not connecting", never connects. The positive path (clock set from real NTP after a cleared clock) was not proven: the clock survived resets in every other run. |
| Session list and time in state | Seen on the board by the user (live sessions); time formatting and `--` for an unset clock: host. |
| Takeover on a waiting question; single answer, multi-select with Done, decline | Host only, with real pointer events at every control. **Not tried live**: no question was sent to the board. |
| Detail screen | Host; opened and navigated on the board by the user. |
| Chime | **Not exercised** (never heard). |
| Idle dim and wake | Dim verified in the log: brightness 70 at boot, 8 exactly 30 s after the last bridge message. Wake on touch: host (`Power`) only. |
| Credentials from sops | **Verified**: `just board creds` writes `app/credentials.env`, which the build reads. |

Not checked, and why:

- **Wi-Fi off and on:** needs control of the access point. Reconnect logic is the C firmware's, ported; backoff is host-tested.
- **Bridge restart with a question open:** needs a deploy of the bridge. The stale-selection case is covered on the host.
- **Colour order and the 80 MHz pixel clock:** the panel runs at the 40 MHz default. Colours looked plausible in the user's photos (pale under a camera) but were never confirmed explicitly.
- **30-minute soak: skipped at the user's request.** Internal RAM was steady at 100 to 111 KB free through every run
  (about 25 minutes of one run on a build that could not connect, and several 30 to 50 s runs with Wi-Fi, TLS and the UI up).
  That is evidence of no fast leak, not of no slow one.

Bugs found by running on the board and fixed: SNTP started before the network was up; every touch release landed
at (0, 0) so no tap registered; the wheel list's rows swung off to the right as they left the screen.
