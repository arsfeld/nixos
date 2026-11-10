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
