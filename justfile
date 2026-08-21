# Import modular justfiles with namespaces
mod blog 'just/blog.just'
mod secrets 'just/secrets.just'
mod docs 'just/docs.just'
fmt:
    alejandra .


# Private recipe to nudge systems back into the default target after activation
_poke-targets *TARGETS:
    #!/usr/bin/env bash
    set -euo pipefail
    targets=({{ TARGETS }})
    if [ ${#targets[@]} -eq 0 ]; then
        mapfile -t targets < <(find hosts -mindepth 2 -maxdepth 2 -name configuration.nix -printf '%h\n' | xargs -r -n1 basename | sort)
    fi

    for target in "${targets[@]}"; do
        echo "Poking multi-user.target on ${target}..."
        if [ "${target}" = "$(hostname)" ]; then
            sudo systemctl start multi-user.target
        else
            ssh "root@${target}.bat-boa.ts.net" sudo systemctl start multi-user.target
        fi
    done

# === Deployment ===
# Phase 1 builds every named host in parallel and pushes to attic; phase 2
# activates each host in parallel from the pre-built closure. Nothing activates
# unless everything builds.

# Expand @tier selectors to hostnames; bare names pass through. Deduped, one
# per line. Every recipe that takes targets routes through this, so tier
# selectors work everywhere and the expansion lives in exactly one place.
_hosts +TARGETS:
    #!/usr/bin/env bash
    set -euo pipefail
    for t in {{ TARGETS }}; do
      case "$t" in
        @*) nix eval --json ".#tiers.${t#@}" | jq -r '.[]' ;;
        *)  echo "$t" ;;
      esac
    done | sort -u

# Private recipe backing deploy/boot/test/dry-run.
_apply ACTION +TARGETS:
    #!/usr/bin/env bash
    set -euo pipefail

    hosts=$(just _hosts {{ TARGETS }} | tr '\n' ' ')
    [ -n "${hosts// /}" ] || { echo "no targets" >&2; exit 1; }

    echo "==> {{ ACTION }}: ${hosts}"
    out=$(mktemp -d)
    trap 'rm -rf "$out"' EXIT INT TERM

    # Phase 1 — parallel eval (one nix-eval-jobs worker per attr) and parallel
    # build. Two flags are load-bearing:
    #   --systems must name both. The default is the local system only, and
    #     nix-fast-build silently drops attrs for any other system, which would
    #     skip basestar (aarch64) entirely.
    #   Do NOT add --skip-cached. It makes nix-eval-jobs skip already-cached
    #     attrs outright, leaving no local store path for --store-path below.
    nix-fast-build \
      --flake '.#deployTargets' \
      --select "t: { inherit (t) ${hosts}; }" \
      --systems "x86_64-linux aarch64-linux" \
      --out-link "$out/result"

    # Resolve the built closures once. `readlink -f` on a missing final
    # component exits 0 and echoes the nonexistent path, so `set -e` will not
    # catch it — check existence explicitly. A host silently dropped by
    # --systems would otherwise reach nixos-rebuild as a bogus --store-path
    # and fail with an obscure nix error instead of naming the real cause.
    declare -A paths
    for h in ${hosts}; do
      [ -e "$out/result-$h" ] || { echo "phase 1 produced no closure for $h" >&2; exit 1; }
      paths[$h]=$(readlink -f "$out/result-$h")
    done

    # Cache push is deliberately best-effort and deliberately NOT
    # nix-fast-build's own --attic-cache. That flag folds upload results into
    # its exit code, so a self-hosted attic being unreachable would abort the
    # deploy *after* paying the full build cost, with every closure fine. The
    # old recipes backgrounded `attic watch-store system &` and swallowed its
    # failure; this preserves that resilience.
    attic push system "${paths[@]}" \
      || echo "warning: attic push failed; deploying anyway" >&2

    # Phase 2 — activate in parallel from the pre-built closures. No re-eval.
    #
    # --no-reexec is REQUIRED, not an optimisation. nixos-rebuild-ng re-execs
    # itself from the target configuration's own nixos-rebuild before doing
    # anything (__init__.py:375). With --flake it resolves that from the flake;
    # with --store-path and no --flake it falls back to `<nixpkgs/nixos>`, and
    # this repo's nix.nixPath is derived from nix.registry with nixpkgs
    # explicitly removed (modules/constellation/common.nix:78), so the lookup
    # finds nothing and nixos-rebuild exits 1 before contacting any host.
    # Suppressing the re-exec is safe here: the closure is already built, and
    # activation runs the *target's* own switch-to-configuration.
    #
    # This failure is invisible to dry-run testing. The re-exec is gated on
    # `can_run = action in (SWITCH, BOOT, TEST)` (__init__.py:371) — DRY_ACTIVATE
    # is not in that tuple, so `just dry-run` never reaches this code path.
    #
    # Each host runs inside a subshell that re-raises PIPESTATUS[0]. Without
    # that, `cmd | sed &` makes $! the PID of *sed*, and `wait` would report
    # sed's exit status — masking every failed activation as a success.
    pids=()
    for h in ${hosts}; do
      p="${paths[$h]}"
      if [ "$h" = "$(hostname)" ]; then
        # Tailscale SSH cannot authenticate a host connecting to itself, so a
        # machine can never deploy itself over --target-host. This branch is
        # what `colmena apply-local` used to be.
        ( sudo nixos-rebuild {{ ACTION }} --no-reexec --store-path "$p" 2>&1 \
            | sed "s/^/[$h] /"; exit "${PIPESTATUS[0]}" ) &
      else
        ( nixos-rebuild {{ ACTION }} --no-reexec --store-path "$p" \
            --target-host "root@$h.bat-boa.ts.net" --use-substitutes 2>&1 \
            | sed "s/^/[$h] /"; exit "${PIPESTATUS[0]}" ) &
      fi
      pids+=($!)
    done
    rc=0
    for pid in "${pids[@]}"; do wait "$pid" || rc=1; done
    exit $rc

#   just deploy galactica raider
#   just deploy @tier1
# Deploy to one or more hosts. Accepts hostnames and @tier selectors.
deploy +TARGETS:
    #!/usr/bin/env bash
    set -euo pipefail
    just _apply switch {{ TARGETS }}
    # Poke the expanded hostnames. Passing {{ TARGETS }} straight through would
    # hand `_poke-targets` a literal "@tier1" and ssh to root@@tier1....
    just _poke-targets $(just _hosts {{ TARGETS }} | tr '\n' ' ')

# Deploy with boot activation (takes effect on next reboot)
boot +TARGETS:
    just _apply boot {{ TARGETS }}

# Activate without making it the boot default
test +TARGETS:
    just _apply test {{ TARGETS }}

# Unlike colmena's dry-run this does build — in exchange it names the units
# that would actually restart.
# Build, then report which units would change.
dry-run +TARGETS:
    just _apply dry-activate {{ TARGETS }}

# Deploy to every discovered host
deploy-all:
    #!/usr/bin/env bash
    set -euo pipefail
    just _apply switch $(just info | tr '\n' ' ')
    just _poke-targets

# nixos-rebuild has no --reboot flag, so the reboot is explicit.
# Deploy with boot activation and reboot (for kernel/bootloader changes).
reboot +TARGETS:
    #!/usr/bin/env bash
    set -euo pipefail
    just _apply boot {{ TARGETS }}
    # Reboot the local machine LAST. _hosts emits names sorted, so rebooting
    # inline would tear this shell down mid-loop and silently skip every host
    # sorted after it — leaving them boot-activated but never rebooted, which
    # is precisely the state this recipe exists to prevent.
    self=""
    for h in $(just _hosts {{ TARGETS }}); do
      if [ "$h" = "$(hostname)" ]; then self="$h"; continue; fi
      echo "Rebooting ${h}..."
      ssh "root@${h}.bat-boa.ts.net" systemctl reboot || true
    done
    if [ -n "$self" ]; then
      echo "Rebooting ${self} (local, last)..."
      sudo systemctl reboot
    fi

# List all known hosts
info:
    nix eval --json '.#hosts' | jq -r '.[]'

# === nixos-rebuild Fallback ===
# Single-host deployment using nixos-rebuild

# Deploy using nixos-rebuild (switch to new configuration)
nr-deploy HOST:
    #!/usr/bin/env bash
    set -euo pipefail
    TARGET="{{ HOST }}.bat-boa.ts.net"
    echo "Deploying {{ HOST }} using nixos-rebuild..."
    nixos-rebuild switch --flake ".#{{ HOST }}" --target-host "root@${TARGET}" --sudo

# Deploy with boot activation using nixos-rebuild
nr-boot HOST:
    #!/usr/bin/env bash
    set -euo pipefail
    TARGET="{{ HOST }}.bat-boa.ts.net"
    echo "Deploying {{ HOST }} with boot activation using nixos-rebuild..."
    nixos-rebuild boot --flake ".#{{ HOST }}" --target-host "root@${TARGET}" --sudo

# Test configuration using nixos-rebuild
nr-test HOST:
    #!/usr/bin/env bash
    set -euo pipefail
    TARGET="{{ HOST }}.bat-boa.ts.net"
    echo "Testing {{ HOST }} configuration using nixos-rebuild..."
    nixos-rebuild test --flake ".#{{ HOST }}" --target-host "root@${TARGET}" --sudo

build HOST:
    nix build '.#deployTargets.{{ HOST }}'

# Build a host and push to Attic cache
cache HOST:
    #!/usr/bin/env bash
    set -euo pipefail

    echo "Building {{ HOST }}..."
    nix build '.#deployTargets.{{ HOST }}' --out-link result-{{ HOST }}

    echo "Pushing {{ HOST }} to Attic cache..."
    attic push system ./result-{{ HOST }}

    rm -f result-{{ HOST }}
    echo "✅ {{ HOST }} built and cached successfully"

# Build NanoPi R2S SD card image
build-r2s:
    #!/usr/bin/env bash
    set -euo pipefail

    echo "Building NanoPi R2S SD card image..."
    nix build ".#r2s" -L

    echo ""
    echo "Image built successfully!"
    echo "Output: ./result/sd-image/"
    echo ""
    echo "To flash the image to an SD card (replace /dev/sdX with your SD card device):"
    echo "  sudo zstdcat ./result/sd-image/*.img.zst | sudo dd of=/dev/sdX bs=16M status=progress conv=fsync"
    echo ""
    echo "After flashing, insert the SD card into the NanoPi R2S and power it on."
    echo "Serial console: 1500000 baud on ttyS2"

# Router testing commands
router-test:
    nix build .#checks.x86_64-linux.router-test -L

# Immich → Pixel stager unit tests
immich-pixel-sync-test:
    nix build .#checks.x86_64-linux.immich-pixel-sync-test -L

# Build Orange Pi Zero 3 SD card image
# Generates a flashable SD card image for the octopi host (Orange Pi Zero 3)
build-octopi:
    #!/usr/bin/env bash
    set -euo pipefail

    echo "Building Orange Pi Zero 3 SD card image..."
    nix build ".#octopi" -L

    echo ""
    echo "✅ Image built successfully!"
    echo "Output: ./result/sd-image/"
    echo ""
    echo "To flash the image to an SD card (replace /dev/sdX with your SD card device):"
    echo "  sudo zstdcat ./result/sd-image/*.img.zst | sudo dd of=/dev/sdX bs=16M status=progress conv=fsync"
    echo ""
    echo "Or decompress and write in two steps:"
    echo "  unzstd ./result/sd-image/*.img.zst"
    echo "  sudo dd if=./result/sd-image/*.img of=/dev/sdX bs=16M status=progress conv=fsync"
    echo ""
    echo "After flashing, insert the SD card into the Orange Pi Zero 3 and power it on."

# Build custom kexec image with Tailscale support
# This kexec image maintains Tailscale connectivity during nixos-anywhere installations
build-kexec:
    #!/usr/bin/env bash
    set -euo pipefail

    echo "Building custom kexec image with Tailscale support..."
    nix build ".#kexec-tailscale" -L

    echo ""
    echo "Kexec image built successfully!"
    echo "Output: ./result"
    echo ""
    echo "To use with nixos-anywhere:"
    echo "  just install <host> <target> ./result"
    echo ""
    echo "Example:"
    echo "  just install pegasus pegasus.bat-boa.ts.net ./result"
    echo ""
    echo "Or manually:"
    echo "  nixos-anywhere --kexec ./result --flake .#<host> root@<target>"

# Build custom installer ISO with disko and automated install script
# Flash to USB for bare-metal NixOS installation
build-installer-iso:
    #!/usr/bin/env bash
    set -euo pipefail

    echo "Building custom NixOS installer ISO..."
    nix build ".#installer-iso" -L

    echo ""
    echo "Installer ISO built successfully!"
    echo "Output: ./result/iso/"
    echo ""
    echo "To flash to a USB drive (replace /dev/sdX with your USB device):"
    echo "  sudo dd if=./result/iso/nixos-*.iso of=/dev/sdX bs=4M status=progress conv=fsync"
    echo ""
    echo "After booting from USB:"
    echo "  1. Connect to WiFi: nmtui"
    echo "  2. Run installer:   sudo /etc/install-nixos.sh blackbird"

# Install any host configuration to a running system via SSH using nixos-anywhere
# WARNING: This will completely wipe and reinstall the target system!
# Usage:
#   just install <host> <target>          # Standard installation (loses Tailscale during kexec)
#   just install <host> <target> ./result # With custom kexec (maintains Tailscale connectivity)
install HOST TARGET_IP KEXEC="":
    #!/usr/bin/env bash
    set -euo pipefail

    echo "Installing {{ HOST }} configuration to {{ TARGET_IP }} using nixos-anywhere..."
    echo ""
    echo "⚠️  WARNING: This will COMPLETELY WIPE the target system!"
    echo ""
    echo "Installation process:"
    echo "  1. Connect to the target host via SSH"
    echo "  2. Preserve Tailscale state if available"
    echo "  3. Boot into installer via kexec (you may lose connection here)"
    echo "  4. Partition and format the disk using disko"
    echo "  5. Install NixOS with the {{ HOST }} configuration"
    echo "  6. Restore preserved state and reboot"

    # Check if using custom kexec
    if [ -n "{{ KEXEC }}" ]; then
        echo ""
        echo "Using custom kexec image: {{ KEXEC }}"
        if [ ! -e "{{ KEXEC }}" ]; then
            echo "Error: Kexec image not found at {{ KEXEC }}"
            echo "Run 'just build-kexec' first to build the custom kexec image"
            exit 1
        fi
    fi
    echo ""
    echo "Prerequisites:"
    echo "  - SSH access as root to the target"
    echo "  - Network connectivity"
    echo ""
    echo "IMPORTANT for Tailscale users:"
    if [ -n "{{ KEXEC }}" ] && [[ "{{ KEXEC }}" == *"result"* ]]; then
        echo "  - Using custom kexec with Tailscale support"
        echo "  - Tailscale connectivity should be maintained during installation"
    else
        echo "  - If connected via Tailscale, you WILL lose connection during kexec"
        echo "  - Ensure the target has a non-Tailscale IP accessible"
        echo "  - Or run this from a machine on the same local network"
        echo "  - Consider using 'just build-kexec' and 'just install <host> <target> ./result'"
    fi
    echo "  - Tailscale will be restored after installation completes"
    echo ""
    read -p "Continue? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Aborted."
        exit 1
    fi

    # Create temporary directory for state preservation
    TMPDIR=$(mktemp -d)
    trap 'rm -rf -- "$TMPDIR"' EXIT

    # Detect if we're using a Tailscale IP
    if [[ {{ TARGET_IP }} == *.ts.net ]] || [[ {{ TARGET_IP }} == 100.* ]]; then
        echo ""
        echo "⚠️  WARNING: You appear to be using a Tailscale address!"
        echo "You will lose connection when the installer starts."
        echo ""
        echo "Alternative options:"
        echo "1. Use the target's local IP address instead"
        echo "2. Set up a jump host on the same network"
        echo "3. Ensure the target has a public IP"
        echo ""
        read -p "Do you want to proceed anyway? (y/N) " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            echo "Aborted. Please use a non-Tailscale IP address."
            exit 1
        fi
    fi

    # Try to preserve Tailscale state if it exists
    echo "Checking for existing Tailscale state..."
    if ssh root@{{ TARGET_IP }} "test -d /var/lib/tailscale || test -d /var/db/tailscale" 2>/dev/null; then
        echo "Found Tailscale state, preserving it..."
        ssh root@{{ TARGET_IP }} "tar -czf - -C / var/lib/tailscale 2>/dev/null || tar -czf - -C / var/db/tailscale 2>/dev/null" > "$TMPDIR/tailscale-state.tar.gz" || {
            echo "Warning: Could not extract Tailscale state."
        }

        if [ -f "$TMPDIR/tailscale-state.tar.gz" ]; then
            mkdir -p "$TMPDIR/extra-files"
            tar -xzf "$TMPDIR/tailscale-state.tar.gz" -C "$TMPDIR/extra-files"
            echo "Tailscale state extracted successfully"
        fi
    else
        echo "No Tailscale state found on target"
    fi

    # Build nixos-anywhere command
    NIXOS_ANYWHERE_CMD="nix run github:nix-community/nixos-anywhere -- --flake .#{{ HOST }}"

    # Add custom kexec if provided
    if [ -n "{{ KEXEC }}" ]; then
        NIXOS_ANYWHERE_CMD="$NIXOS_ANYWHERE_CMD --kexec {{ KEXEC }}"
    fi

    # Add extra files if we have them
    if [ -d "$TMPDIR/extra-files" ] && [ -n "$(ls -A "$TMPDIR/extra-files")" ]; then
        NIXOS_ANYWHERE_CMD="$NIXOS_ANYWHERE_CMD --extra-files $TMPDIR/extra-files"
    fi

    # Always copy host keys if they exist
    NIXOS_ANYWHERE_CMD="$NIXOS_ANYWHERE_CMD --copy-host-keys"

    # Install using nixos-anywhere
    echo ""
    echo "Starting installation..."
    echo "NOTE: You may see 'Connection closed' - this is expected during kexec."
    $NIXOS_ANYWHERE_CMD root@{{ TARGET_IP }}

    echo ""
    echo "Installation complete! The system should automatically reboot."
    if [ -d "$TMPDIR/extra-files" ] && [ -n "$(ls -A "$TMPDIR/extra-files")" ]; then
        echo "Tailscale state has been preserved - after reboot, the host will be accessible via Tailscale."
    fi
    echo ""
    echo "After reboot:"
    echo "  - If Tailscale was preserved: Connect via {{ HOST }}.bat-boa.ts.net"
    echo "  - Otherwise: Connect via {{ TARGET_IP }} and run 'tailscale up'"
    echo "  - Deploy updates with: just deploy {{ HOST }}"


# Install NixOS on a running Linux system using nixos-infect
# This is useful for systems where nixos-anywhere cannot be used (e.g., when only Tailscale access is available)
install-infect HOST TARGET_HOST:
    #!/usr/bin/env bash
    set -euo pipefail

    echo "Installing {{ HOST }} on {{ TARGET_HOST }} using nixos-infect..."
    echo ""
    echo "This method:"
    echo "  - Converts an existing Linux system to NixOS in-place"
    echo "  - Preserves Tailscale authentication"
    echo "  - Maintains SSH connectivity (mostly)"
    echo "  - Works when you only have Tailscale access"
    echo ""
    echo "Prerequisites:"
    echo "  - Target must be running a supported Linux distribution"
    echo "  - Root SSH access must be available"
    echo "  - At least 2GB of free disk space"
    echo ""
    read -p "Continue? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Aborted."
        exit 1
    fi

    # Copy and run the install script
    echo "Copying installation script to target..."
    scp hosts/{{ HOST }}/install-nixos.sh root@{{ TARGET_HOST }}:/tmp/

    echo "Running installation script..."
    echo "NOTE: You may temporarily lose connection during the conversion"
    ssh root@{{ TARGET_HOST }} "bash /tmp/install-nixos.sh" || {
        echo ""
        echo "Connection lost (this is expected during nixos-infect)"
        echo "The system should reboot into NixOS automatically"
        echo ""
        echo "Wait a few minutes and try connecting again:"
        echo "  ssh root@{{ TARGET_HOST }}"
        echo ""
        echo "If using Tailscale, the host should remain accessible"
    }

# Generate hardware configuration for any host
hardware-config HOST TARGET_HOST:
    #!/usr/bin/env bash
    set -euo pipefail

    echo "Generating hardware configuration for {{ HOST }} at {{ TARGET_HOST }}..."

    # Create host directory if it doesn't exist
    mkdir -p hosts/{{ HOST }}

    # Generate hardware config on the target
    ssh root@{{ TARGET_HOST }} nixos-generate-config --show-hardware-config > hosts/{{ HOST }}/hardware-configuration.nix

    echo "Hardware configuration saved to hosts/{{ HOST }}/hardware-configuration.nix"
    echo "Review the file and commit it to the repository."

# Apply disko configuration to format and partition disks on a host
# WARNING: This will DESTROY ALL DATA on the configured disks!
# Usage: just disko <host> <target>
# Example: just disko pegasus root@pegasus.bat-boa.ts.net
disko HOST TARGET:
    #!/usr/bin/env bash
    set -euo pipefail

    echo "Applying disko configuration for {{ HOST }} to {{ TARGET }}..."
    echo ""
    echo "⚠️  WARNING: This will DESTROY ALL DATA on the configured disks!"
    echo ""
    echo "This command will:"
    echo "  1. Copy the disko configuration to {{ TARGET }}"
    echo "  2. Run disko on the target system"
    echo "  3. Partition and format all configured disks"
    echo "  4. Create filesystems (including ZFS pools if configured)"
    echo "  5. Mount everything according to the configuration"
    echo ""

    # Check if disko config exists
    if [ ! -f "hosts/{{ HOST }}/disko-config.nix" ]; then
        echo "Error: No disko configuration found at hosts/{{ HOST }}/disko-config.nix"
        exit 1
    fi

    # Show disk configuration summary
    echo "Disk configuration preview:"
    if grep -q "zpool" "hosts/{{ HOST }}/disko-config.nix"; then
        echo "  - ZFS pool configuration detected"
        grep -E "(pool = |type = \"zpool\"|mode = )" "hosts/{{ HOST }}/disko-config.nix" | sed 's/^/    /'
    fi
    if grep -q "disk = {" "hosts/{{ HOST }}/disko-config.nix"; then
        echo "  - Disk devices:"
        grep -E "device = " "hosts/{{ HOST }}/disko-config.nix" | sed 's/^/    /'
    fi
    echo ""

    read -p "Are you ABSOLUTELY SURE you want to continue? Type 'yes' to proceed: " confirmation
    if [[ "$confirmation" != "yes" ]]; then
        echo "Aborted."
        exit 1
    fi

    echo ""
    echo "Copying disko configuration to target..."

    # Copy the disko configuration to the target
    scp "hosts/{{ HOST }}/disko-config.nix" "{{ TARGET }}:/tmp/disko-config.nix"

    echo "Running disko on the target system..."

    # Run disko on the target system
    # Using --mode destroy,format,mount to wipe, format and mount
    # Add --debug for more verbose output if needed
    ssh "{{ TARGET }}" "nix run github:nix-community/disko -- --mode destroy,format,mount --yes-wipe-all-disks /tmp/disko-config.nix"

    echo ""
    echo "✅ Disko configuration applied successfully!"
    echo ""
    echo "The disks have been formatted and mounted at /mnt on the target system."
    echo ""
    echo "Next steps:"
    echo "  - To install NixOS: just install {{ HOST }} {{ TARGET }}"
    echo "  - To check the mounted filesystems: ssh {{ TARGET }} 'df -h; zfs list 2>/dev/null || true'"
    echo ""
    echo "Note: If this is a ZFS system, the pool has been created but won't persist"
    echo "across reboots until NixOS is installed with the proper configuration."

# List network interfaces on router in Nix configuration format
router-interfaces TARGET_HOST:
    #!/usr/bin/env bash
    set -euo pipefail

    ssh root@{{ TARGET_HOST }} bash << 'EOF'
        # Get all physical interfaces
        interfaces=()
        for iface in $(ls /sys/class/net/ | sort); do
            if [[ -d "/sys/class/net/$iface/device" ]]; then
                mac=$(cat "/sys/class/net/$iface/address" 2>/dev/null || echo "unknown")
                carrier=$(cat "/sys/class/net/$iface/carrier" 2>/dev/null || echo "0")
                link_status="DOWN"
                [[ "$carrier" == "1" ]] && link_status="UP"
                interfaces+=("$iface|$mac|$link_status")
            fi
        done

        # Output in the desired format
        echo "  router.interfaces = {"

        i=0
        for entry in "${interfaces[@]}"; do
            IFS='|' read -r iface mac link <<< "$entry"

            case $i in
                0) echo "    wan = \"$iface\";    # WAN interface (MAC: $mac, Link: $link)" ;;
                1) echo "    lan1 = \"$iface\";   # First LAN port (MAC: $mac, Link: $link)" ;;
                2) echo "    lan2 = \"$iface\";   # Second LAN port (MAC: $mac, Link: $link)" ;;
                3) echo "    lan3 = \"$iface\";   # Third LAN port (MAC: $mac, Link: $link)" ;;
                *) echo "    # Extra interface: $iface (MAC: $mac, Link: $link)" ;;
            esac

            ((i++))
        done

        echo "  };"
    EOF



# Create a new secret file with a random value
# Usage: just secret-create <secret-name>
# Example: just secret-create planka-db-password
secret-create SECRET_NAME:
    #!/usr/bin/env bash
    set -euo pipefail

    # Check if ragenix is available
    if ! command -v ragenix &> /dev/null; then
        echo "Error: ragenix command not found. Please enter the development shell with 'nix develop'"
        exit 1
    fi

    # Generate a random secret
    SECRET_VALUE=$(openssl rand -base64 32)

    # Create temporary file with the secret
    TMPFILE=$(mktemp)
    trap 'rm -f "$TMPFILE"' EXIT
    echo "$SECRET_VALUE" > "$TMPFILE"

    # Encrypt the secret
    cd secrets && EDITOR="cp $TMPFILE" ragenix -e "{{ SECRET_NAME }}.age"

    echo "✅ Secret '{{ SECRET_NAME }}.age' created successfully"
    echo "Don't forget to add it to secrets/secrets.nix if needed!"
