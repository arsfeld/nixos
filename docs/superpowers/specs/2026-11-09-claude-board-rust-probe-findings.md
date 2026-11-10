# Claude Board Rust firmware: probe findings

Date: 2026-11-09. Source: `firmware/probe-rust/` (throwaway, deleted in Task 14 of
`docs/superpowers/plans/2026-11-09-claude-board-rust.md`), with the working notes in its `README.md`.
Spec: `docs/superpowers/specs/2026-11-09-claude-board-rust-design.md`.

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
