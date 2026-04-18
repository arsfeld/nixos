#!/usr/bin/env bash
set -euo pipefail

# Re-exec as root if not already
if [ "$(id -u)" -ne 0 ]; then
  exec sudo NIX_CONFIG="experimental-features = nix-command flakes" "$0" "$@"
fi

export NIX_CONFIG="experimental-features = nix-command flakes"

HOSTNAME="${1:-blackbird}"
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"

echo "=== NixOS Installer ==="
echo ""
echo "Target host: $HOSTNAME"
echo "Config repo: $REPO_DIR"
echo ""

# Verify host configuration exists
if [ ! -f "$REPO_DIR/hosts/$HOSTNAME/configuration.nix" ]; then
  echo "ERROR: No configuration found for host '$HOSTNAME'"
  echo "Available hosts:"
  for d in "$REPO_DIR"/hosts/*/; do
    [ -f "$d/configuration.nix" ] && echo "  - $(basename "$d")"
  done
  exit 1
fi
echo "Host configuration found: $HOSTNAME"

# Step 1: Run disko to partition and format
echo ""
echo "[1/2] Partitioning and formatting disks with disko..."
echo ""
echo "WARNING: This will DESTROY ALL DATA on the target disk(s)!"
echo ""

if [ -f "$REPO_DIR/hosts/$HOSTNAME/disko-config.nix" ]; then
  echo "Disk configuration:"
  grep 'device = ' "$REPO_DIR/hosts/$HOSTNAME/disko-config.nix" | sed 's/^/  /'
fi
echo ""

read -p "Continue with disk formatting? (y/N) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
  echo "Aborted."
  exit 1
fi

nix run github:nix-community/disko -- \
  --mode destroy,format,mount \
  --yes-wipe-all-disks \
  "$REPO_DIR/hosts/$HOSTNAME/disko-config.nix"

echo "  Disks partitioned and mounted at /mnt."

# Step 2: Install NixOS
echo "[2/2] Installing NixOS configuration '$HOSTNAME'..."
nixos-install --flake "$REPO_DIR#$HOSTNAME" --no-root-password

echo ""
echo "=== Installation complete! ==="
echo ""
echo "Next steps:"
echo "  1. reboot"
echo "  2. Remove the USB drive"
echo "  3. Run 'tailscale up' for Tailscale access"
