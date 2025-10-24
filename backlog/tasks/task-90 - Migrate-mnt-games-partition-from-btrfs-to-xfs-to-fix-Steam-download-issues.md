---
id: task-90
title: Migrate /mnt/games partition from btrfs to xfs to fix Steam download issues
status: In Progress
assignee: []
created_date: '2025-10-23 16:15'
updated_date: '2025-10-23 20:56'
labels:
  - nixos
  - filesystem
  - gaming
  - steam
  - raider
dependencies: []
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Steam downloads get stuck at "Reserving Space" on the current btrfs filesystem due to Copy-on-Write issues. Migrating to xfs will eliminate these problems.

The /mnt/games partition is on nvme0n1p1 (1.9TB) and contains only Steam games that can be re-downloaded.

Current configuration in hosts/raider/disko-config.nix uses btrfs for this disk.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Disko configuration updated to use xfs instead of btrfs for nvme0n1p1
- [ ] #2 Configuration deployed to raider host
- [x] #3 Partition reformatted as xfs
- [x] #4 /mnt/games mount point working with xfs
- [ ] #5 Steam able to download games without getting stuck on 'Reserving Space'
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Update fileSystems./mnt/games configuration in hosts/raider/configuration.nix:
   - Change fsType from "btrfs" to "xfs"
   - Replace btrfs-specific mount options with xfs-appropriate options
   - Keep UUID-based device identifier (will remain valid after reformat)

2. Deploy configuration to raider host:
   - Use `just deploy raider` to build and deploy
   - Configuration will be staged but partition won't change until reformatted

3. Reformat partition (on raider host):
   - Unmount /mnt/games
   - Run mkfs.xfs on the partition
   - Remount /mnt/games (systemd will use new xfs configuration)

4. Verify Steam can download games without issues
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Confirmed partition is already formatted as XFS with UUID 3caa4963-867f-4a76-bbbb-3792d10adc3f

Added x-systemd.nofail mount option to prevent boot failures if disk not found

Disko config already correctly specifies XFS formatting
<!-- SECTION:NOTES:END -->
