# The ESP32-S3 AMOLED session board: back up, build, flash and restore its firmware
# (firmware/claude-board). Recipes run inside `nix develop .#firmware`, so they work from any
# shell. The serial port needs the dialout group (modules/hosts/raider/esp32-board.nix); until
# the next login after that deploys, they fall back to sudo.

FW := justfile_directory() / "firmware/claude-board"
BACKUP_DIR := env_var("HOME") / ".local/share/esp32-amoled"
PORT := env_var_or_default("BOARD_PORT", "/dev/ttyACM0")

# Read the whole 32 MB flash to a dated file. Run this before the first custom flash: restoring
# it puts the stock Waveshare demo back.
backup:
    #!/usr/bin/env bash
    set -euo pipefail
    mkdir -p '{{ BACKUP_DIR }}'
    out="{{ BACKUP_DIR }}/full-flash-backup-$(date +%F).bin"
    [ ! -e "$out" ] || { echo "$out already exists; refusing to overwrite it" >&2; exit 1; }
    nix develop .#firmware -c bash -c '
      set -euo pipefail
      run() { if [ -w "{{ PORT }}" ]; then "$@"; else sudo env "PATH=$PATH" "$@"; fi; }
      run esptool --port "{{ PORT }}" --baud 921600 read-flash 0 0x2000000 "'"$out"'"
    '
    [ "$(stat -c %s "$out")" = 33554432 ] || { echo "backup is not 32 MiB; do not trust it" >&2; exit 1; }
    sha256sum "$out" | tee "$out.sha256"
    echo "backup OK: $out"

# Write a full-flash backup back (default: the newest one). Restores the stock demo firmware.
restore FILE="":
    #!/usr/bin/env bash
    set -euo pipefail
    f='{{ FILE }}'
    [ -n "$f" ] || f="$(ls -t '{{ BACKUP_DIR }}'/full-flash-backup-*.bin | head -n1)"
    [ "$(stat -c %s "$f")" = 33554432 ] || { echo "$f is not a 32 MiB image" >&2; exit 1; }
    (cd "$(dirname "$f")" && sha256sum -c "$(basename "$f").sha256")
    nix develop .#firmware -c bash -c '
      set -euo pipefail
      run() { if [ -w "{{ PORT }}" ]; then "$@"; else sudo env "PATH=$PATH" "$@"; fi; }
      run esptool --port "{{ PORT }}" --baud 921600 write-flash 0 "'"$f"'"
    '

# Host tests for the board's protocol crate (wire types and model), against the bridge's fixtures.
test:
    #!/usr/bin/env bash
    set -euo pipefail
    nix develop .#firmware -c bash -c 'cd "{{ justfile_directory() }}/packages/claude-board-proto" && cargo test'

# Host tests for the old C protocol core, kept until the C firmware is retired (plain C and cJSON, built with ASan and UBSan).
# The fixtures are the bridge's wire format; the Rust side pins the same files.
test-c:
    #!/usr/bin/env bash
    set -euo pipefail
    nix develop .#firmware -c bash -c '
      set -euo pipefail
      cd "{{ FW }}/components/board_proto"
      out="$(mktemp -d)"
      trap "rm -rf $out" EXIT
      cc -std=c11 -Wall -Wextra -Werror -g -fsanitize=address,undefined -fno-sanitize-recover=all \
        -DFIX_DIR=\"{{ justfile_directory() }}/packages/claude-board-bridge/tests/fixtures/board\" \
        -I. $(pkg-config --cflags libcjson) board_proto.c test/test_board_proto.c \
        $(pkg-config --libs libcjson) -o "$out/test"
      "$out/test"
    '

# Render the Slint screens to PNGs in firmware/claude-board/preview/ (host only, no board needed).
preview:
    #!/usr/bin/env bash
    set -euo pipefail
    nix develop .#firmware -c bash -c 'cd "{{ FW }}" && ./scripts/vendor-slint-core.sh >/dev/null && cargo run -q -p claude-board-ui --example preview -- preview 2>/dev/null'

# Write the Wi-Fi credentials and the device token from sops into the firmware's gitignored
# sdkconfig.defaults.local, and drop sdkconfig so the next build picks them up. Nothing is printed.
# They end up in the flash image in the clear (flash encryption is not enabled): anyone with the
# board in hand can read them back, so treat the board like the credentials it holds.
creds:
    #!/usr/bin/env bash
    set -euo pipefail
    nix develop .#firmware -c bash -c '
      set -euo pipefail
      out="{{ FW }}/sdkconfig.defaults.local"
      sops_file="{{ justfile_directory() }}/secrets/sops/raider.yaml"
      # An empty value must stop the recipe: a failure inside $(...) in an argument would not.
      get() {
        local v
        v="$(sops --decrypt --extract "[\"$1\"]" "$sops_file")"
        [ -n "$v" ] || { echo "secret $1 is empty or missing" >&2; exit 1; }
        v=${v//\\/\\\\}
        printf "%s" "${v//\"/\\\"}"
      }
      ssid="$(get claude-board-wifi-ssid)"
      pass="$(get claude-board-wifi-pass)"
      token="$(get claude-board-device-token)"
      : > "$out"
      chmod 600 "$out"
      printf "CONFIG_CLAUDE_BOARD_WIFI_SSID=\"%s\"\n" "$ssid" >> "$out"
      printf "CONFIG_CLAUDE_BOARD_WIFI_PASS=\"%s\"\n" "$pass" >> "$out"
      printf "CONFIG_CLAUDE_BOARD_TOKEN=\"%s\"\n" "$token" >> "$out"
      # The Rust firmware reads KEY=value lines (no quoting) from app/credentials.env at build time.
      penv="{{ FW }}/app/credentials.env"
      : > "$penv"
      chmod 600 "$penv"
      printf "CB_WIFI_SSID=%s\nCB_WIFI_PASS=%s\nCB_TOKEN=%s\n" "$ssid" "$pass" "$token" >> "$penv"
    '
    rm -f '{{ FW }}/sdkconfig'
    echo "wrote {{ FW }}/sdkconfig.defaults.local; run just board build"

# Build the OLD C firmware (kept until the Rust one has replaced it).
#
# The first configure is seeded with kconfig-seed.json. The IDF component manager (2.2.2 in IDF
# 5.5.x) evaluates optional dependencies that are conditioned on Kconfig symbols (LVGL 9.6's
# freetype/png/jpeg/lz4, the BSP adapter's button/fs/knob/decoder) before any component, and so
# any Kconfig file defining them, has been downloaded. With no symbol values known it fails with
# MissingKconfigError and downloads nothing. It reads known values from build/config/sdkconfig.json
# when that exists, so the first configure starts from a seed with those features off; the real
# sdkconfig.json replaces it from then on. If a newer lvgl or adapter adds another conditional
# dependency the same error names the symbol: add it to the seed. dependencies.lock pins versions.
build-c:
    #!/usr/bin/env bash
    set -euo pipefail
    nix develop .#firmware -c bash -c '
      set -euo pipefail
      cd "{{ FW }}"
      if [ ! -f sdkconfig ]; then
        rm -rf build
        mkdir -p build/config
        cp kconfig-seed.json build/config/sdkconfig.json
        idf.py -DIDF_TARGET=esp32s3 reconfigure
      fi
      idf.py build
    '

# Flash the old C firmware (bootloader, partition table, app) and reboot the board.
flash-c:
    #!/usr/bin/env bash
    set -euo pipefail
    nix develop .#firmware -c bash -c '
      set -euo pipefail
      cd "{{ FW }}/build"
      run() { if [ -w "{{ PORT }}" ]; then "$@"; else sudo env "PATH=$PATH" "$@"; fi; }
      run esptool --chip esp32s3 --port "{{ PORT }}" --baud 921600 write-flash "@flash_args"
    '

# Follow the old C firmware's log (needs a terminal; Ctrl-] quits).
monitor-c:
    nix develop .#firmware -c bash -c 'cd "{{ FW }}" && idf.py -p "{{ PORT }}" monitor'

# Build the Rust firmware (app/). esp-idf-sys does not notice changes to the C component, sdkconfig.defaults
# or the Cargo metadata, so it is cleaned first when any of them is newer than the last build.
build:
    #!/usr/bin/env bash
    set -euo pipefail
    nix develop .#firmware -c bash -c '
      set -euo pipefail
      cd "{{ FW }}"
      ./scripts/vendor-slint-core.sh >/dev/null
      cd app
      stamp=target/.inputs-stamp
      if [ ! -f "$stamp" ] || [ -n "$(find components sdkconfig.defaults Cargo.toml partitions.csv -newer "$stamp" -print -quit)" ]; then
        cargo clean -p esp-idf-sys --release 2>/dev/null || true
      fi
      cargo build --release
      touch "$stamp"
    '

# Flash the Rust firmware and reboot the board. The partition table is given here, not in the build:
# esp-idf-sys ignores CONFIG_PARTITION_TABLE_*.
flash:
    #!/usr/bin/env bash
    set -euo pipefail
    nix develop .#firmware -c bash -c '
      set -euo pipefail
      cd "{{ FW }}/app"
      out="$(ls -td target/xtensa-esp32s3-espidf/release/build/esp-idf-sys-*/out/build | head -n1)"
      run() { if [ -w "{{ PORT }}" ]; then "$@"; else sudo env "PATH=$PATH" "$@"; fi; }
      run espflash flash --chip esp32s3 --port "{{ PORT }}" --flash-size 16mb \
        --bootloader "$out/bootloader/bootloader.bin" --partition-table partitions.csv \
        --ignore-app-descriptor target/xtensa-esp32s3-espidf/release/claude-board
    '

# Follow the board's log (needs a terminal; Ctrl-C quits).
monitor:
    nix develop .#firmware -c bash -c 'cd "{{ FW }}/app" && espflash monitor --port "{{ PORT }}"'
