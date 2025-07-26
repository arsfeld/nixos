#!/usr/bin/env bash
# Prepare cottage for nixos-infect by creating the necessary ZFS dataset

set -euo pipefail

echo "This script prepares the cottage system for nixos-infect"
echo "It will create a new ZFS dataset for NixOS root filesystem"
echo ""
echo "Current ZFS datasets in boot-pool:"
zfs list -r boot-pool

echo ""
echo "Creating boot-pool/ROOT/nixos dataset..."
zfs create -o mountpoint=legacy boot-pool/ROOT/nixos || {
    echo "Dataset already exists or creation failed"
    echo "If it exists, you may want to destroy it first:"
    echo "  zfs destroy -r boot-pool/ROOT/nixos"
    exit 1
}

echo ""
echo "Dataset created successfully!"
echo "You can now run nixos-infect"
echo ""
echo "Note: The nixos-infect process will:"
echo "1. Install NixOS to boot-pool/ROOT/nixos"
echo "2. Keep the existing Tailscale state"
echo "3. Use the existing EFI partition"
echo ""
echo "After nixos-infect completes, you can recreate the data pool as needed"