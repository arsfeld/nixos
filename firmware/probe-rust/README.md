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
