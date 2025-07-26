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

# Build custom kexec image with Tailscale support
build-kexec-tailscale:
    #!/usr/bin/env bash
    set -euo pipefail
    
    echo "Building custom kexec image with Tailscale support..."
    nix build ".#kexec-tailscale" -L
    
    echo ""
    echo "Kexec image built successfully!"
    echo "Output: ./result"
    echo ""
    echo "To use with nixos-anywhere:"
    echo "  just install-tailscale <host> <target>"
    echo ""
    echo "Or manually:"
    echo "  nixos-anywhere --kexec ./result --flake .#<host> root@<target>"

# Install any host configuration using nixos-anywhere with Tailscale-enabled kexec
# This maintains Tailscale connectivity throughout the installation process
install-tailscale HOST TARGET_IP:
    #!/usr/bin/env bash
    set -euo pipefail
    
    echo "Installing {{ HOST }} to {{ TARGET_IP }} using nixos-anywhere with Tailscale kexec..."
    echo ""
    echo "This method uses a custom kexec image that includes Tailscale,"
    echo "allowing you to maintain connectivity throughout the installation."
    echo ""
    
    # Build the kexec image if it doesn't exist
    if [ ! -e result ] || [ ! -e result/kexec-installer ]; then
        echo "Building custom kexec image..."
        nix build ".#kexec-tailscale" -L || {
            echo "Failed to build kexec image"
            exit 1
        }
    fi
    
    echo "Using kexec image at: ./result"
    echo ""
    read -p "Continue with installation? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Aborted."
        exit 1
    fi
    
    # Create temporary directory for state preservation
    TMPDIR=$(mktemp -d)
    trap 'rm -rf -- "$TMPDIR"' EXIT
    
    # Try to preserve Tailscale state
    echo "Checking for existing Tailscale state..."
    if ssh root@{{ TARGET_IP }} "test -d /var/lib/tailscale || test -d /var/db/tailscale" 2>/dev/null; then
        echo "Found Tailscale state, preserving it..."
        ssh root@{{ TARGET_IP }} "tar -czf - -C / var/lib/tailscale 2>/dev/null || tar -czf - -C / var/db/tailscale 2>/dev/null" > "$TMPDIR/tailscale-state.tar.gz" || {
            echo "Warning: Could not extract Tailscale state."
        }
        
        if [ -f "$TMPDIR/tailscale-state.tar.gz" ] && [ -s "$TMPDIR/tailscale-state.tar.gz" ]; then
            echo "Uploading Tailscale state to target..."
            scp "$TMPDIR/tailscale-state.tar.gz" root@{{ TARGET_IP }}:/tmp/ || {
                echo "Warning: Could not upload Tailscale state"
            }
        fi
    fi
    
    echo ""
    echo "Running nixos-anywhere with custom kexec..."
    echo "The target will reboot into the installer with Tailscale support."
    echo ""
    
    # Prepare extra files if we have them
    EXTRA_FILES_ARG=""
    if [ -d "$TMPDIR/extra-files" ] && [ -n "$(ls -A "$TMPDIR/extra-files")" ]; then
        EXTRA_FILES_ARG="--extra-files $TMPDIR/extra-files"
    fi
    
    # Run nixos-anywhere with our custom kexec
    nix run github:nix-community/nixos-anywhere -- \
        --kexec ./result \
        --flake .#{{ HOST }} \
        --copy-host-keys \
        $EXTRA_FILES_ARG \
        root@{{ TARGET_IP }}
    
    echo ""
    echo "Installation complete!"
    echo "The system should be accessible via Tailscale at {{ HOST }}.bat-boa.ts.net"

# Install any host configuration to a running system via SSH using nixos-anywhere
# WARNING: This will completely wipe and reinstall the target system!
install HOST TARGET_IP:
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
    echo ""
    echo "Prerequisites:"
    echo "  - SSH access as root to the target"
    echo "  - Network connectivity"
    echo ""
    echo "IMPORTANT for Tailscale users:"
    echo "  - If connected via Tailscale, you WILL lose connection during kexec"
    echo "  - Ensure the target has a non-Tailscale IP accessible"
    echo "  - Or run this from a machine on the same local network"
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
# Router UI development commands
router-ui-dev:
    #!/usr/bin/env bash
    set -euo pipefail
    
    echo "Starting Router UI development server..."
    cd packages/router_ui
    
    # Enter nix shell and run Go server
    nix shell "nixpkgs#go" "nixpkgs#nodejs" "nixpkgs#nodePackages.npm" "nixpkgs#tailwindcss" -c bash -c '
        # Download Go dependencies and create go.sum
        echo "Downloading Go dependencies..."
        go mod tidy
        
        # Install web dependencies if needed
        if [ ! -d "web/node_modules" ]; then
            echo "Installing npm dependencies..."
            cd web && npm install --legacy-peer-deps && cd ..
        fi
        
        # Build web assets
        echo "Building web assets..."
        cd web
        tailwindcss -i ./src/css/app.css -o ./static/css/app.css --minify
        cp ./src/js/app.js ./static/js/app.js
        cp node_modules/alpinejs/dist/cdn.min.js ./static/js/alpine.min.js
        cd ..
        
        # Create data directory for development and clean up any locks
        mkdir -p /tmp/router-ui-dev
        rm -f /tmp/router-ui-dev/db/LOCK
        
        # Start Go server
        echo "Starting Router UI server on http://localhost:4000"
        go run main.go -db /tmp/router-ui-dev/db -port 4000
    '

router-ui-setup:
    #!/usr/bin/env bash
    set -euo pipefail
    
    echo "Setting up Router UI development environment..."
    cd packages/router_ui
    
    nix shell "nixpkgs#go" "nixpkgs#nodejs" "nixpkgs#nodePackages.npm" "nixpkgs#tailwindcss" -c bash -c '
        # Download Go dependencies and create go.sum
        echo "Downloading Go dependencies..."
        go mod tidy
        
        # Install npm dependencies
        echo "Installing npm dependencies..."
        cd web && npm install --legacy-peer-deps && cd ..
        
        # Build web assets
        echo "Building web assets..."
        cd web
        mkdir -p static/css static/js
        tailwindcss -i ./src/css/app.css -o ./static/css/app.css --minify
        cp ./src/js/app.js ./static/js/app.js
        cp node_modules/alpinejs/dist/cdn.min.js ./static/js/alpine.min.js
        cd ..
        
        echo "✓ Router UI setup complete!"
        echo "Run 'just router-ui-dev' to start the development server"
    '

router-ui-test:
    #!/usr/bin/env bash
    set -euo pipefail
    
    echo "Running Router UI tests..."
    cd packages/router_ui
    
    nix shell "nixpkgs#go" -c go test ./...

router-ui-build:
    #!/usr/bin/env bash
    set -euo pipefail
    
    echo "Building Router UI release..."
    cd packages/router_ui
    
    nix build ./. -L
    echo "✓ Router UI built successfully!"
    
    # Also push to cache if available
    if command -v attic &> /dev/null; then
        echo "Pushing to cache..."
        attic push system result
    fi

router-ui-watch:
    #!/usr/bin/env bash
    set -euo pipefail
    
    echo "Starting Router UI with hot-reload..."
    cd packages/router_ui
    
    nix shell "nixpkgs#go" "nixpkgs#nodejs" "nixpkgs#nodePackages.npm" "nixpkgs#tailwindcss" "nixpkgs#entr" -c bash -c '
        # Download Go dependencies and create go.sum
        echo "Downloading Go dependencies..."
        go mod tidy
        
        # Install dependencies if needed
        if [ ! -d "web/node_modules" ]; then
            echo "Installing npm dependencies..."
            cd web && npm install --legacy-peer-deps && cd ..
        fi
        
        # Create data directory for development and clean up any locks
        mkdir -p /tmp/router-ui-dev
        rm -f /tmp/router-ui-dev/db/LOCK
        
        # Create directories
        mkdir -p web/static/css web/static/js
        
        # Copy JS files
        cp web/src/js/app.js web/static/js/app.js
        cp web/node_modules/alpinejs/dist/cdn.min.js web/static/js/alpine.min.js
        
        # Build CSS initially
        echo "Building CSS..."
        cd web
        tailwindcss -i ./src/css/app.css -o ./static/css/app.css --minify
        cd ..
        
        # Run tailwindcss watch in background
        echo "Starting CSS watcher..."
        cd web
        tailwindcss -i ./src/css/app.css -o ./static/css/app.css --watch &
        CSS_PID=$!
        cd ..
        
        # Function to cleanup background process
        cleanup() {
            echo "Stopping CSS watcher..."
            kill $CSS_PID 2>/dev/null || true
        }
        trap cleanup EXIT
        
        # Watch Go files and restart on changes
        echo "Starting Go server with auto-reload..."
        find . -name "*.go" -o -name "*.html" | entr -r go run main.go -db /tmp/router-ui-dev/db -port 4000
    '

router-ui-deploy TARGET="router":
    #!/usr/bin/env bash
    set -euo pipefail
    
    echo "Deploying Router UI to {{ TARGET }}..."
    
    # Build the package first
    echo "Building Router UI..."
    cd packages/router_ui && nix build ./. -L
    
    # Deploy the configuration
    echo "Deploying to {{ TARGET }}..."
    just deploy {{ TARGET }}
    
    echo "✓ Router UI deployed to {{ TARGET }}"
    echo "Access it at: http://{{ TARGET }}.bat-boa.ts.net:4000 or via Caddy proxy"

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
