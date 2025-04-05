fmt: 
    nix fmt

args := "--skip-checks"

boot +TARGETS: 
    #!/usr/bin/env bash
    set -euo pipefail # Enable strict error handling
    targets_formatted=$(printf ".#%s " {{ TARGETS }})
    deploy {{ args }} --boot --targets ${targets_formatted% }

deploy *TARGETS:
    #!/usr/bin/env bash
    set -euo pipefail # Enable strict error handling
    targets_formatted=$(printf ".#%s " {{ TARGETS }})
    echo "Deploying to targets: ${targets_formatted% }"
    deploy {{ args }} --targets ${targets_formatted% }

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
