# Import modular justfiles with namespaces
mod blog 'just/blog.just'
mod secrets 'just/secrets.just'
mod docs 'just/docs.just'
mod supabase 'just/supabase.just'

fmt:
    nix fmt


args := "--skip-checks"


# Private recipe to format targets with .# prefix
_format-targets +TARGETS:
    #!/usr/bin/env bash
    printf ".#%s " {{ TARGETS }} | sed 's/ $//'

boot +TARGETS:
    #!/usr/bin/env bash
    set -euo pipefail # Enable strict error handling
    deploy {{ args }} --boot --targets $(just _format-targets {{ TARGETS }})

deploy +TARGETS:
    #!/usr/bin/env bash
    set -euo pipefail # Enable strict error handling
    
    # If running on storage host, cache builds first to prevent GC issues
    if [[ "$(hostname)" == "storage" ]]; then
        echo "Caching builds to Attic before deployment..."
        for target in {{ TARGETS }}; do
            echo "Caching $target..."
            OUTPUT=$(nix build ".#nixosConfigurations.$target.config.system.build.toplevel" --no-link --print-out-paths)
            if [ -n "$OUTPUT" ]; then
                attic push system "$OUTPUT" || echo "Warning: Failed to push $target to cache"
            fi
        done
    fi
    
    # Build deploy command with multiple --targets flags
    cmd="deploy {{ args }}"
    for target in {{ TARGETS }}; do
        cmd="$cmd --targets \".#$target\""
    done
    echo "Running: $cmd"
    eval $cmd

# Deploy using Colmena (alternative to deploy-rs)
colmena-deploy +TARGETS:
    #!/usr/bin/env bash
    set -euo pipefail
    colmena apply --impure --on {{ TARGETS }} --verbose

# Deploy with boot activation using Colmena
colmena-boot +TARGETS:
    #!/usr/bin/env bash
    set -euo pipefail
    colmena apply --impure --on {{ TARGETS }} --reboot --verbose

# Build configuration using Colmena without deploying
colmena-build +TARGETS:
    #!/usr/bin/env bash
    set -euo pipefail
    colmena build --impure --on {{ TARGETS }}

# Show Colmena deployment information
colmena-info:
    colmena eval --impure -E '{ nodes, ... }: builtins.attrNames nodes'

# Interactive Colmena deployment
colmena-interactive:
    colmena apply --impure --interactive

trace +TARGETS:
    #!/usr/bin/env bash
    set -euo pipefail # Enable strict error handling
    deploy {{ args }} --targets $(just _format-targets {{ TARGETS }}) -- --show-trace

build HOST:
    nix build '.#nixosConfigurations.{{ HOST }}.config.system.build.toplevel'
    attic push system result

# Cache a specific host configuration to Attic
cache HOST:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "Building and caching {{ HOST }}..."
    OUTPUT=$(nix build '.#nixosConfigurations.{{ HOST }}.config.system.build.toplevel' --no-link --print-out-paths)
    echo "Pushing to Attic cache..."
    attic push system "$OUTPUT"
    echo "{{ HOST }} cached successfully"

# Deploy with automatic caching
deploy-cached HOST *ARGS:
    just cache {{ HOST }}
    just deploy {{ HOST }} {{ ARGS }}

r2s:
    #!/usr/bin/env bash
    set -euo pipefail # Enable strict error handling

    # --- Configuration ---
    # Define the output directory for the final image
    FINAL_OUTPUT_DIR="r2s-output"
    # NixOS configuration file for the SD image
    SD_IMAGE_CONFIG="./hosts/r2s/sd-image.nix"
    # U-Boot flake reference
    UBOOT_FLAKE_REF="github:EHfive/flakes#packages.aarch64-linux.ubootNanopiR2s"
    # Target architecture
    TARGET_ARCH="aarch64-linux"

    # --- Setup ---
    # Create a temporary directory for build artifacts and ensure cleanup on exit
    TMPDIR=$(mktemp -d)
    trap 'rm -rf -- "$TMPDIR"' EXIT
    echo "Working in temporary directory: $TMPDIR"

    # Create the final output directory if it doesn't exist
    mkdir -p "$FINAL_OUTPUT_DIR"

    # --- Build Nix Artefacts ---
    echo "Building NixOS SD image..."
    nix build --impure --expr "(import <nixpkgs/nixos> { system = \"$TARGET_ARCH\"; configuration = $SD_IMAGE_CONFIG; }).config.system.build.sdImage" --out-link "$TMPDIR/sd-image-result"

    echo "Building U-Boot..."
    nix build "$UBOOT_FLAKE_REF" --out-link "$TMPDIR/uboot-result"

    # --- Prepare File Paths ---
    # Get the full path to the compressed SD image
    SD_IMAGE_ZST_PATH=$(readlink -f "$TMPDIR/sd-image-result"/sd-image/*)
    SD_IMAGE_ZST_NAME=$(basename "$SD_IMAGE_ZST_PATH")
    # Derive the uncompressed image name
    SD_IMAGE_NAME="${SD_IMAGE_ZST_NAME%.zst}"
    # Full path for the uncompressed image in the temporary directory
    RAW_IMAGE_PATH="$TMPDIR/$SD_IMAGE_NAME"
    # Paths to the bootloader components
    IDBLOADER_PATH=$(readlink -f "$TMPDIR/uboot-result/idbloader.img")
    UBOOT_ITB_PATH=$(readlink -f "$TMPDIR/uboot-result/u-boot.itb")
    # Final path for the compressed image in the output directory
    FINAL_ZST_PATH="$FINAL_OUTPUT_DIR/$SD_IMAGE_NAME.zst"

    # --- Image Manipulation ---
    echo "Extracting SD image..."
    unzstd -f "$SD_IMAGE_ZST_PATH" -o "$RAW_IMAGE_PATH"

    echo "Writing bootloaders to image..."
    # Write idbloader.img (U-Boot SPL) to sector 64 (offset 32 KiB)
    dd if="$IDBLOADER_PATH" of="$RAW_IMAGE_PATH" conv=fsync,notrunc bs=512 seek=64
    # Write u-boot.itb (main U-Boot image) to sector 16384 (offset 8 MiB)
    dd if="$UBOOT_ITB_PATH" of="$RAW_IMAGE_PATH" conv=fsync,notrunc bs=512 seek=16384

    echo "Compressing final image..."
    # Compress the modified raw image and place it in the final output directory
    zstd -f "$RAW_IMAGE_PATH" -o "$FINAL_ZST_PATH"

    # --- Completion ---
    # Cleanup: The trap command automatically removes $TMPDIR on script exit (success or failure)
    echo "✅ Image built successfully: $FINAL_ZST_PATH"
    echo ""
    echo "To burn the image to an SD card (replace /dev/sdX):"
    echo "  sudo dd if='$FINAL_ZST_PATH' of=/dev/sdX bs=16M status=progress conv=fsync"
    echo ""
    echo "To create a compressed archive:"
    ARCHIVE_NAME="nanopi-nixos-$(date --rfc-3339=date).img.xz"
    echo "  tar -c -I 'xz -9 -T0' -f '$ARCHIVE_NAME' '$FINAL_ZST_PATH'"

# The trap ensures TMPDIR is cleaned up automatically

# Router testing commands
router-test:
    nix build .#checks.x86_64-linux.router-test -L

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
    echo "  just install cottage cottage.bat-boa.ts.net ./result"
    echo ""
    echo "Or manually:"
    echo "  nixos-anywhere --kexec ./result --flake .#<host> root@<target>"


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
# Example: just disko cottage root@cottage.bat-boa.ts.net
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



# Setup Plausible Analytics secrets
plausible-setup:
    #!/usr/bin/env bash
    set -euo pipefail
    
    # Colors for output
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    NC='\033[0m' # No Color
    
    echo -e "${GREEN}Setting up Plausible Analytics secrets...${NC}"
    
    # Check if ragenix is available
    if ! command -v ragenix &> /dev/null; then
        echo -e "${RED}Error: ragenix command not found. Please enter the development shell with 'nix develop'${NC}"
        exit 1
    fi
    
    # Save the original directory
    ORIG_DIR=$(pwd)
    
    # Generate SECRET_KEY_BASE
    echo -e "${YELLOW}Generating SECRET_KEY_BASE...${NC}"
    SECRET_KEY=$(openssl rand -base64 64 | tr -d '\n=')
    echo "SECRET_KEY_BASE=${SECRET_KEY}" > /tmp/plausible-secret-key.txt
    
    # Encrypt the secret key
    echo -e "${YELLOW}Encrypting SECRET_KEY_BASE...${NC}"
    cd "$ORIG_DIR/secrets" && ragenix -e plausible-secret-key.age --editor "sh -c 'cat > \$1' --" < /tmp/plausible-secret-key.txt
    rm -f /tmp/plausible-secret-key.txt
    
    echo -e "${GREEN}✓ SECRET_KEY_BASE generated and encrypted${NC}"
    
    # Handle SMTP password
    echo -e "${YELLOW}Setting up SMTP password...${NC}"
    echo -e "Do you want to:"
    echo -e "1) Reuse the existing system SMTP password (smtp_password.age)"
    echo -e "2) Enter a new SMTP password for Plausible"
    read -p "Choose option (1 or 2): " choice
    
    case $choice in
        1)
            # Reuse existing SMTP password
            echo -e "${YELLOW}Decrypting existing SMTP password...${NC}"
            
            # Create a temporary file for the decrypted password
            TEMP_SMTP=$(mktemp)
            trap "rm -f ${TEMP_SMTP}" EXIT
            
            # Decrypt the existing SMTP password
            cd "$ORIG_DIR/secrets" && age -d -i ~/.ssh/id_ed25519 smtp_password.age > "${TEMP_SMTP}"
            
            # Format it for Plausible's environment variable
            echo "SMTP_USER_PWD=$(cat ${TEMP_SMTP})" > /tmp/plausible-smtp-password.txt
            
            # Encrypt for Plausible
            cd "$ORIG_DIR/secrets" && ragenix -e plausible-smtp-password.age --editor "sh -c 'cat > \$1' --" < /tmp/plausible-smtp-password.txt
            rm -f /tmp/plausible-smtp-password.txt
            
            echo -e "${GREEN}✓ Existing SMTP password reused for Plausible${NC}"
            ;;
        2)
            # Get new SMTP password
            echo -e "${YELLOW}Enter the SMTP password for Plausible:${NC}"
            read -s smtp_password
            echo
            
            # Create the environment variable file
            echo "SMTP_USER_PWD=${smtp_password}" > /tmp/plausible-smtp-password.txt
            
            # Encrypt the SMTP password
            cd "$ORIG_DIR/secrets" && ragenix -e plausible-smtp-password.age --editor "sh -c 'cat > \$1' --" < /tmp/plausible-smtp-password.txt
            rm -f /tmp/plausible-smtp-password.txt
            
            echo -e "${GREEN}✓ New SMTP password encrypted for Plausible${NC}"
            ;;
        *)
            echo -e "${RED}Invalid option. Exiting.${NC}"
            exit 1
            ;;
    esac
    
    echo -e "${GREEN}✅ All Plausible secrets have been set up successfully!${NC}"
    echo -e "${YELLOW}Next steps:${NC}"
    echo -e "1. Commit the new secret files: git add secrets/plausible-*.age"
    echo -e "2. Deploy to the cloud host: just deploy cloud"
    echo -e "3. Visit https://plausible.arsfeld.dev to create your admin account"
