# Cottage NixOS Infect Notes

This configuration has been adapted to work with nixos-infect on the existing TrueNAS SCALE installation.

## Changes Made

1. **Removed disko import** - The system will use existing ZFS pools instead of creating new ones
2. **Updated hardware-configuration.nix** - Configured to import the existing boot-pool
3. **Disabled services** - Temporarily disabled backup, media, and MinIO services that depend on the data pool
4. **Boot configuration** - Uses the existing EFI partition at /dev/sde2

## Installation Process

1. **On the cottage system**, prepare the ZFS dataset:
   ```bash
   sudo zfs create -o mountpoint=legacy boot-pool/ROOT/nixos
   ```

2. **Run nixos-infect** from the cottage system:
   ```bash
   curl https://raw.githubusercontent.com/elitak/nixos-infect/master/nixos-infect | NIX_CHANNEL=nixos-24.11 bash -x
   ```

3. **Important**: The system will preserve:
   - Tailscale state (maintains connectivity)
   - SSH host keys
   - Network configuration

## Post-Installation

After successful nixos-infect:

1. The system will boot from `boot-pool/ROOT/nixos`
2. The data pool will be available but not mounted
3. You can recreate the data pool with proper datasets for media storage

## Reverting Changes

To use this configuration with nixos-anywhere again:
1. Re-enable the disko import in configuration.nix
2. Re-enable the backup and media modules
3. Uncomment the MinIO service in services/default.nix

## Boot Pool Structure

The boot-pool uses ZFS datasets similar to TrueNAS:
- `boot-pool/ROOT/nixos` - NixOS root filesystem
- `boot-pool/grub` - GRUB bootloader files (existing)
- `/dev/sde2` - EFI System Partition (FAT32)