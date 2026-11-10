# Throwaway Rust probe

Phase 0 of `docs/superpowers/plans/2026-11-09-claude-board-rust.md`. Answers whether the Rust and Slint
firmware is viable on this board. Deleted in Task 14; findings live in
`docs/superpowers/specs/2026-11-09-claude-board-rust-probe-findings.md`.

## Toolchain (Task 1)

- **Compiler:** Espressif's Xtensa Rust fork, from `github:leighleighleigh/esp-rs-nix` (flake input
  `esp-rs-nix`, `flake = false`, used only for its `package.nix`). It fetches Espressif's rust-build
  release by fixed hash, so it is reproducible. Chosen over `espup` (imperative, installs under
  `~/.rustup`) and over `nixpkgs-esp-dev` (has no Rust toolchain). Selected through
  `RUSTUP_TOOLCHAIN=<store path>`, so there is no `rust-toolchain.toml` here.
- **Shell:** `nix develop .#firmware` also provides `espflash`, `ldproxy`, `rustup`, `libclang`
  (`LIBCLANG_PATH`, for `esp-idf-sys`'s bindgen) and sets `ESP_IDF_TOOLS_INSTALL_DIR=fromenv`, so
  `esp-idf-sys` builds against the nix ESP-IDF v5.5.4 (`IDF_PATH`) rather than downloading its own.
- **Crates:** `esp-idf-svc` 0.53, `esp-idf-sys` 0.38.1, `esp-idf-hal` 0.47.

## Build and flash

    nix develop .#firmware -c bash -c 'cd firmware/probe-rust && cargo build --release'

Flash with `espflash flash --chip esp32s3 --flash-size 16mb --bootloader <bootloader.bin>
--partition-table <partition-table.bin> --ignore-app-descriptor <elf>`, using the two `.bin` files that
`esp-idf-sys` leaves under `target/.../esp-idf-sys-*/out/build/`.

## Findings from Task 2 (Wi-Fi, TLS, websocket)

- The websocket client is not in `esp-idf-svc` by default: add `espressif/esp_websocket_client` as an
  `extra_components` remote component in `Cargo.toml`. After changing that metadata run
  `cargo clean -p esp-idf-sys --release`, because `esp-idf-sys` does not rerun on its own.
- `esp-idf-sys` ignores `CONFIG_PARTITION_TABLE_*` (its README says so). The app is built regardless and the
  partition table is given at flash time: `espflash flash --partition-table partitions.csv`. Without it the
  image does not fit the default 1 MB partition once Wi-Fi is linked.
- Credentials: `just board creds` now also writes `credentials.env` (gitignored); `build.rs` turns it into
  `env!` values.
- Result on the board: Wi-Fi up in about 5 s (WPA3-SAE), clock set 1.8 s later, `Certificate validated`, and the
  first frame from the live bridge was `{"t":"state","sessions":[...`. Internal RAM with Wi-Fi and TLS up and no
  display: free 188,863 bytes, largest block 114,688, PSRAM free 7.1 MB.

## Findings from Task 3 (Slint on the panel)

**Result: it works on the board, Wi-Fi, TLS and the websocket running at the same time.** Measured on the
panel with the probe scene (five rim arcs with one pulsing, a breathing orb, a ring and a tinted glow):

| Scene | fps | render | panel push | dirty area |
|---|---|---|---|---|
| rim pulse and centre together | 28 to 29 | 18 to 20 ms | 12 ms | 328 rows, 314 px wide |
| centre only (ring, orb, glow) | 36 | 16 ms | 8 ms | 201 rows |
| rim pulse only | 59 | 3 ms | 6 ms | 154 rows |

Internal RAM with everything running: about 110 KB free, 63 KB largest block. Flash image: 1.89 MB of the
6 MB app partition. Not yet confirmed by eye (the board cannot be seen from here): colour order (the first
6 s show red, green and blue bars; the code swaps bytes), and no artefacts at the 80 MHz pixel clock.

What had to change to get there, all of it needed again in the real app:

- **No LVGL, no BSP package.** `waveshare/esp32_s3_touch_amoled_1_75` depends on LVGL, and the component
  manager then fails with `MissingKconfigError: LV_USE_FREETYPE` inside `esp-idf-sys`, which offers no place to
  seed it. `components/board_display` carries a trimmed copy of the BSP code it needs (Apache-2.0, noted in the
  file): pins, CO5300 QSPI init, brightness, CST9217 touch, ES8311 speaker. It depends only on `esp_lcd_co5300`,
  `esp_lcd_touch`, `esp_lcd_panel_io_additions`, `esp_codec_dev` and `waveshare/esp_lcd_touch_cst9217`.
- **I2C:** `esp-idf-hal` links the legacy driver and the new driver aborts at start. Fixed with
  `CONFIG_I2C_SKIP_LEGACY_CONFLICT_CHECK=y`.
- **Slint features:** `std` pulls in `fontique` and `memmap2`, which do not build for ESP-IDF. Use
  `["compat-1-2", "renderer-software", "unsafe-single-threaded", "libm", "software-renderer-path"]`.
  `Path` then needs a one-line local patch to `i-slint-core` 1.18.1 (`f32::rem_euclid` does not exist without
  std); `scripts/vendor-slint-core.sh` makes the patched copy in `vendor/` and `Cargo.toml` patches to it.
  Slint's compiler also needs `fontconfig` on the host (`pkg-config` plus `fontconfig`).
- **Push path:** non-blocking `bd_draw` of up to 16 rows, two alternating internal DMA buffers, a 32-bit byte
  swap, and one `bd_wait` per frame. A binary semaphore loses completions: it must be a counting one. Push
  fell from 60 ms to 17 ms per full frame. The pixel clock was raised from 40 to 80 MHz (full frame 27 ms at 40).
- **Damage regions decide the frame rate.** A `Path` with an animated property repaints its whole box every
  frame, even when hidden (the probe's first version repainted all 217,156 pixels every frame and ran at 8 fps).
  Give every arc its own tight box, create hidden animated items with `if`, and push only the dirty rows.
- **Rendering limits found on the host and the board:** a `Rectangle` with `border-radius` cannot hold a
  gradient (it renders as a rounded square), and a `Path` filled with a radial gradient renders flat. The glow
  is a pre-rendered white sprite tinted with `colorize`. Scaling that sprite costs about 20 ms per frame at
  240 px, so use it at native size. Rendering through an internal line buffer was slower, not faster.
- **Build gotchas:** after editing the C component run `cargo clean -p esp-idf-sys --release`, because
  `esp-idf-sys` does not notice it (an hour of stale measurements). The same goes for `Cargo.toml` metadata.
