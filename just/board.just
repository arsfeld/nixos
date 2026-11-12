# The ESP32-S3 AMOLED session board: back up, build, flash and restore its firmware
# (firmware/cylon-bot). Recipes run inside `nix develop .#firmware`, so they work from any
# shell. The serial port needs the dialout group (modules/hosts/raider/esp32-board.nix); until
# the next login after that deploys, they fall back to sudo.

FW := justfile_directory() / "firmware/cylon-bot"
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
    nix develop .#firmware -c bash -c 'cd "{{ justfile_directory() }}/packages/cylon-bot-proto" && cargo test'

# Render the Slint screens to PNGs in firmware/cylon-bot/preview/ (host only, no board needed).
preview:
    #!/usr/bin/env bash
    set -euo pipefail
    nix develop .#firmware -c bash -c 'cd "{{ FW }}" && ./scripts/vendor-slint.sh >/dev/null && cargo run -q -p cylon-bot-ui --example preview -- preview 2>/dev/null'

# Write the Wi-Fi networks (a list, tried by signal strength) and the device token from sops into the firmware's gitignored
# app/credentials.env, which the build turns into compile-time values. Nothing is printed.
# They end up in the flash image in the clear (flash encryption is not enabled): anyone with the
# board in hand can read them back, so treat the board like the credentials it holds.
# (Optional extra lines in that file: CB_URL, CB_NTP, CB_DNS, read by app/build.rs.)
creds:
    #!/usr/bin/env bash
    set -euo pipefail
    nix develop .#firmware -c bash -c '
      set -euo pipefail
      out="{{ FW }}/app/credentials.env"
      sops_file="{{ justfile_directory() }}/secrets/sops/raider.yaml"
      # An empty value must stop the recipe: a failure inside $(...) in an argument would not. The file is
      # KEY=value lines read as they are, so a value spanning lines would corrupt it.
      get() {
        local v
        v="$(sops --decrypt --extract "[\"$1\"]" "$sops_file")"
        [ -n "$v" ] || { echo "secret $1 is empty or missing" >&2; exit 1; }
        [ "$(printf "%s" "$v" | wc -l)" = 0 ] || { echo "secret $1 spans several lines" >&2; exit 1; }
        printf "%s" "$v"
      }
      token="$(get cylon-bot-device-token)"
      # The Wi-Fi networks are a list of {ssid, pass}; each becomes a CB_WIFI_SSID/CB_WIFI_PASS pair of
      # lines, in list order (the order breaks signal ties). An open network has an empty pass.
      wifi="$(sops --decrypt --extract "[\"cylon-bot-wifi-networks\"]" --output-type json "$sops_file" \
        | jq -r ".[] | if (.ssid | type) != \"string\" or .ssid == \"\" or ((.pass // \"\") | test(\"\n\")) or (.ssid | test(\"\n\")) then error(\"bad Wi-Fi entry\") else \"CB_WIFI_SSID=\(.ssid)\nCB_WIFI_PASS=\(.pass // \"\")\" end")"
      [ -n "$wifi" ] || { echo "secret cylon-bot-wifi-networks is empty or missing" >&2; exit 1; }
      : > "$out"
      chmod 600 "$out"
      printf "%s\nCB_TOKEN=%s\n" "$wifi" "$token" >> "$out"
    '
    echo "wrote {{ FW }}/app/credentials.env; run just board build"

# Build the Rust firmware (app/). esp-idf-sys does not notice changes to the C component, sdkconfig.defaults
# or the Cargo metadata, so it is cleaned first when any of them is newer than the last build.
build:
    #!/usr/bin/env bash
    set -euo pipefail
    nix develop .#firmware -c bash -c '
      set -euo pipefail
      cd "{{ FW }}"
      ./scripts/vendor-slint.sh >/dev/null
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
        --ignore-app-descriptor target/xtensa-esp32s3-espidf/release/cylon-bot
    '

# Follow the board's log (needs a terminal; Ctrl-C quits).
monitor:
    nix develop .#firmware -c bash -c 'cd "{{ FW }}/app" && espflash monitor --port "{{ PORT }}"'
