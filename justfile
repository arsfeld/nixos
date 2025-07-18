fmt:
    nix fmt

# Documentation commands
docs-serve:
    devenv shell -- mkdocs serve --dev-addr 127.0.0.1:8000

docs-build:
    devenv shell -- mkdocs build

docs-deploy:
    devenv shell -- mkdocs gh-deploy --force

args := "--skip-checks"

# Supabase management commands
supabase-create INSTANCE:
    modules/supabase/scripts/create-instance {{INSTANCE}}

supabase-delete INSTANCE:
    modules/supabase/scripts/delete-instance {{INSTANCE}}

supabase-update-secret INSTANCE SECRET:
    modules/supabase/scripts/update-secret {{INSTANCE}} {{SECRET}}

supabase-status:
    #!/usr/bin/env bash
    echo "=== Supabase Instances ==="
    for instance in /var/lib/supabase-*; do
        if [ -d "$instance" ]; then
            name=$(basename "$instance" | sed 's/supabase-//')
            echo "Instance: $name"
            if systemctl is-active --quiet "supabase-$name"; then
                echo "  Status: Running"
                echo "  Port: $(grep -o '${toString port}' "$instance/docker-compose.yml" 2>/dev/null || echo "Unknown")"
            else
                echo "  Status: Stopped"
            fi
            echo
        fi
    done

supabase-info:
    modules/supabase/scripts/info

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
    deploy {{ args }} --targets $(just _format-targets {{ TARGETS }})

trace +TARGETS:
    #!/usr/bin/env bash
    set -euo pipefail # Enable strict error handling
    deploy {{ args }} --targets $(just _format-targets {{ TARGETS }}) -- --show-trace

build HOST:
    nix build '.#nixosConfigurations.{{ HOST }}.config.system.build.toplevel'
    attic push system result

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

router-test-production:
    nix build .#checks.x86_64-linux.router-test-production -L

# Install any host configuration to a running NixOS system via SSH using nixos-anywhere
install HOST TARGET_IP:
    #!/usr/bin/env bash
    set -euo pipefail
    
    echo "Installing {{ HOST }} configuration to {{ TARGET_IP }} using nixos-anywhere..."
    echo "This will:"
    echo "  1. Connect to the target host via SSH"
    echo "  2. Partition and format the disk using disko"
    echo "  3. Install NixOS with the {{ HOST }} configuration"
    echo ""
    echo "Prerequisites:"
    echo "  - Target host must be booted into NixOS installer ISO"
    echo "  - SSH access as root must be enabled"
    echo "  - Network connectivity must be working"
    echo ""
    read -p "Continue? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Aborted."
        exit 1
    fi
    
    # Install using nixos-anywhere
    nix run github:nix-community/nixos-anywhere -- \
        --flake .#{{ HOST }} \
        root@{{ TARGET_IP }}
    
    echo ""
    echo "Installation complete! The system should automatically reboot."
    echo "After reboot, you can deploy updates with: just deploy {{ HOST }}"
    echo ""
    echo "First steps after installation:"
    echo "  1. Set up Tailscale: tailscale up"
    echo "  2. Monitor services: systemctl status"
    echo "  3. Check host-specific configuration"

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

# Secret management commands
secret-generate NAME LENGTH="64":
    #!/usr/bin/env bash
    set -euo pipefail
    
    # Check if agenix is available
    if ! command -v agenix &> /dev/null; then
        echo "Error: agenix command not found. Please enter the development shell with 'nix develop'"
        exit 1
    fi
    
    echo "Generating {{ LENGTH }}-character key for {{ NAME }}..."
    
    # Generate the key
    key=$(openssl rand -base64 {{ LENGTH }} | tr -d '\n=' | head -c {{ LENGTH }})
    
    # Save to temporary file
    echo "$key" > "/tmp/{{ NAME }}.txt"
    
    # Encrypt with agenix (run from secrets directory)
    echo "Encrypting {{ NAME }}..."
    cd secrets && agenix -e "{{ NAME }}.age" < "/tmp/{{ NAME }}.txt"
    rm -f "/tmp/{{ NAME }}.txt"
    
    echo "✓ Key generated and encrypted to secrets/{{ NAME }}.age"
    echo "Don't forget to add it to secrets/secrets.nix!"

secret-copy SOURCE DEST:
    #!/usr/bin/env bash
    set -euo pipefail
    
    if ! command -v agenix &> /dev/null; then
        echo "Error: agenix command not found. Please enter the development shell with 'nix develop'"
        exit 1
    fi
    
    if [ ! -f "secrets/{{ SOURCE }}" ]; then
        echo "Error: Source secret secrets/{{ SOURCE }} not found"
        exit 1
    fi
    
    echo "Copying secret from {{ SOURCE }} to {{ DEST }}..."
    
    # Create temporary file
    temp_file=$(mktemp)
    trap "rm -f $temp_file" EXIT
    
    # Decrypt source (run from secrets directory)
    cd secrets && agenix -d "{{ SOURCE }}" > "$temp_file"
    
    # Re-encrypt to destination
    agenix -e "{{ DEST }}" < "$temp_file"
    
    echo "✓ Secret copied to secrets/{{ DEST }}"
    echo "Don't forget to add it to secrets/secrets.nix with appropriate publicKeys!"

secret-show NAME:
    #!/usr/bin/env bash
    set -euo pipefail
    
    if ! command -v agenix &> /dev/null; then
        echo "Error: agenix command not found. Please enter the development shell with 'nix develop'"
        exit 1
    fi
    
    if [ ! -f "secrets/{{ NAME }}" ]; then
        echo "Error: Secret secrets/{{ NAME }} not found"
        exit 1
    fi
    
    echo "⚠️  WARNING: This will display the secret in plain text!"
    read -p "Are you sure you want to continue? (yes/no): " confirm
    
    if [ "$confirm" != "yes" ]; then
        echo "Aborted."
        exit 0
    fi
    
    echo "Decrypting {{ NAME }}..."
    echo "--- BEGIN SECRET ---"
    cd secrets && agenix -d "{{ NAME }}"
    echo -e "\n--- END SECRET ---"

secret-list:
    #!/usr/bin/env bash
    echo "Available secrets:"
    if [ -d "secrets" ]; then
        ls -la secrets/*.age 2>/dev/null | awk '{print "  " $9}' | sed 's|secrets/||g' || echo "  No secrets found"
    else
        echo "Error: secrets directory not found"
    fi

# Build and serve the blog locally for testing
blog-serve PORT="8000":
    #!/usr/bin/env bash
    set -euo pipefail
    
    # Try to get local IP address
    LOCAL_IP=$(ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v '127.0.0.1' | head -n1 || echo "localhost")
    
    echo "Building and serving blog on http://0.0.0.0:{{ PORT }}"
    echo "Blog will be accessible at:"
    echo "  - http://localhost:{{ PORT }}"
    if [ "$LOCAL_IP" != "localhost" ]; then
        echo "  - http://${LOCAL_IP}:{{ PORT }}"
    fi
    
    echo "Press Ctrl+C to stop the server"
    
    # Use the local IP as the base URL so assets load correctly from remote hosts
    cd blog && nix run 'nixpkgs#zola' -- serve --interface 0.0.0.0 --port {{ PORT }} --base-url "http://${LOCAL_IP}"

# Build the blog without serving
blog-build:
    #!/usr/bin/env bash
    set -euo pipefail
    
    echo "Building blog..."
    cd blog && nix run 'nixpkgs#zola' -- build
    echo "✓ Blog built successfully in blog/public/"

# Check the blog for issues
blog-check:
    #!/usr/bin/env bash
    set -euo pipefail
    
    echo "Checking blog for issues..."
    cd blog && nix run 'nixpkgs#zola' -- check
    echo "✓ Blog check completed"

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
    
    # Check if agenix is available
    if ! command -v agenix &> /dev/null; then
        echo -e "${RED}Error: agenix command not found. Please enter the development shell with 'nix develop'${NC}"
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
    cd "$ORIG_DIR/secrets" && agenix -e plausible-secret-key.age < /tmp/plausible-secret-key.txt
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
            cd "$ORIG_DIR/secrets" && agenix -d smtp_password.age > "${TEMP_SMTP}"
            
            # Format it for Plausible's environment variable
            echo "SMTP_USER_PWD=$(cat ${TEMP_SMTP})" > /tmp/plausible-smtp-password.txt
            
            # Encrypt for Plausible
            cd "$ORIG_DIR/secrets" && agenix -e plausible-smtp-password.age < /tmp/plausible-smtp-password.txt
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
            cd "$ORIG_DIR/secrets" && agenix -e plausible-smtp-password.age < /tmp/plausible-smtp-password.txt
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
