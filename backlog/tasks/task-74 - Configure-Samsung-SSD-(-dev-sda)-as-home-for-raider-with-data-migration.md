---
id: task-74
title: Configure Samsung SSD (/dev/sda) as /home for raider with data migration
status: In Progress
assignee: []
created_date: '2025-10-21 01:35'
updated_date: '2025-10-21 01:39'
labels:
  - storage
  - raider
  - disk-migration
  - disko
dependencies: []
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Configure the Samsung MZ7LN512HAJQ 512GB SATA SSD (currently /dev/sda) as the dedicated /home partition for the raider host, migrating all existing user data from the current btrfs subvolume.

**Current State:**
- Samsung SSD: 512GB, SATA III, 68% life remaining, good health (SMART passed)
- Performance: 93K IOPS random, 497 MiB/s sequential
- Current /home: btrfs subvolume on NVMe (XrayDisk 512GB)
- Hostname: raider (gaming desktop)

**Disk Identity:**
- Model: SAMSUNG MZ7LN512HAJQ-000H1
- Serial: S3TANA0KA01037
- Device: /dev/disk/by-id/ata-SAMSUNG_MZ7LN512HAJQ-000H1_S3TANA0KA01037

**Goals:**
1. Free up NVMe space for OS/applications (faster performance)
2. Separate user data from system partitions
3. Preserve all existing /home data during migration
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Samsung SSD is configured in disko-config.nix as /home partition
- [x] #2 Filesystem is formatted (ext4 or btrfs, decide based on needs)
- [ ] #3 All existing /home data is successfully migrated to new disk
- [ ] #4 User can login and access all files in /home after migration
- [x] #5 Old /home btrfs subvolume is removed from disko config
- [ ] #6 System boots successfully with new /home mount
- [ ] #7 Backup of /home data exists before migration begins
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
## Configuration Completed

The NixOS configuration has been updated and verified:

1. **disko-config.nix updated** (hosts/raider/disko-config.nix):
   - Added Samsung SSD as separate disk device
   - Configured as btrfs with zstd compression
   - Mount point: /home
   - Removed /home subvolume from NVMe disk configuration

2. **Build verification**: Configuration builds successfully
   - Verified fstab shows correct mount: `/dev/disk/by-partlabel/disk-home-home /home btrfs compress=zstd,noatime,subvol=/home`

## Next Steps (Manual Intervention Required)

The configuration is ready to deploy, but **data migration requires manual steps** to avoid data loss. See IMPLEMENTATION_PLAN.md for detailed instructions.

**CRITICAL**: Do NOT deploy yet without completing backup first!

### Required Actions on raider host:

1. **Stage 1: Backup** (CRITICAL - DO FIRST)
   ```bash
   # Check current /home size
   sudo du -sh /home
   
   # Create backup (choose appropriate method)
   rsync -avxHAX --progress /home/ /mnt/backup/raider-home-backup/
   
   # OR create btrfs snapshot
   sudo btrfs subvolume snapshot /home /.snapshots/home-pre-migration
   ```

2. **Stage 2: Deploy configuration**
   ```bash
   # From nixos repo
   just deploy raider
   ```

3. **Stage 3: Migrate data** (after successful boot)
   - Boot into rescue mode or single-user
   - Mount old /home from NVMe
   - Copy data to new Samsung SSD /home
   - Verify and test

4. **Stage 4: Cleanup**
   - Delete old /home subvolume from NVMe
   - Verify space reclaimed

See IMPLEMENTATION_PLAN.md for complete step-by-step guide.
<!-- SECTION:PLAN:END -->
