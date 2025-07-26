# ZFS Status Report for NixOS Repository

## Summary

After reviewing the entire repository, here's the current status of ZFS usage:

## Hosts with ZFS Explicitly Configured

### 1. **cottage** - ZFS ENABLED ✓
- `boot.supportedFilesystems = [ "zfs" ];`
- Uses ZFS for boot pool (boot-pool/ROOT/nixos)
- Has ZFS-specific boot configuration
- Currently adapted for nixos-infect installation

### 2. **raider** - ZFS EXPLICITLY DISABLED ✗
- `boot.supportedFilesystems = lib.mkForce ["btrfs" "cifs" "f2fs" "jfs" "ntfs" "reiserfs" "vfat" "xfs" "bcachefs"];`
- Comment says "Remove zfs"
- Intentionally excludes ZFS from supported filesystems

### 3. **g14** - ZFS EXPLICITLY DISABLED ✗
- Same as raider: explicitly removes ZFS support
- `boot.supportedFilesystems = lib.mkForce [...]` without ZFS

### 4. **storage** - ZFS NOT INCLUDED
- `boot.supportedFilesystems = ["bcachefs"];`
- Only supports bcachefs, no ZFS

### 5. **striker** - ZFS NOT EXPLICITLY SET
- Has `gnomeExtensions.zfs-status-monitor` installed
- But no ZFS filesystem support configured
- This might cause the extension to be non-functional

## Hosts with Default Configuration

The following hosts don't explicitly set `supportedFilesystems`:
- cloud
- cloud-br
- core
- hpe
- micro
- r2s
- raspi3
- router

These hosts will use NixOS defaults, which typically include common filesystems but may or may not include ZFS depending on the NixOS version and configuration.

## Potential Issues Found

1. **striker** has `gnomeExtensions.zfs-status-monitor` installed but doesn't explicitly enable ZFS support. This extension won't work properly without ZFS.

2. **raider** and **g14** explicitly disable ZFS, which is fine if they don't use ZFS pools.

3. **cottage** has been temporarily modified for nixos-infect:
   - Disabled disko import
   - Disabled backup and media modules
   - These changes need to be reverted after successful installation

## Recommendations

1. **For striker**: Either remove `gnomeExtensions.zfs-status-monitor` or add ZFS support if needed.

2. **For cottage**: After nixos-infect installation:
   - Re-enable disko import if using nixos-anywhere in the future
   - Re-enable backup and media modules once data pool is recreated
   - Uncomment MinIO service

3. **For hosts without explicit supportedFilesystems**: Consider explicitly setting supported filesystems to avoid surprises with NixOS defaults changing.

## No Unintended Consequences Found

The ZFS disabling appears intentional and limited to:
- **raider** and **g14**: Explicitly don't want ZFS
- **storage**: Only uses bcachefs
- **cottage**: Temporarily modified for migration

All other hosts either don't use ZFS or rely on NixOS defaults, which should be fine for their use cases.