# Implementation Plan: Migrate /home to Samsung SSD

**Task**: Configure Samsung SSD (/dev/sda) as /home for raider with data migration
**Task ID**: task-74
**Priority**: High

## Overview

This plan migrates the /home partition from a btrfs subvolume on the NVMe drive to a dedicated Samsung MZ7LN512HAJQ 512GB SATA SSD. The migration will preserve all user data and ensure system stability.

## Current State

- **System**: raider (gaming desktop)
- **Current /home**: btrfs subvolume on XrayDisk 512GB NVMe
- **Target disk**: Samsung MZ7LN512HAJQ-000H1 (512GB SATA SSD)
- **Disk ID**: `/dev/disk/by-id/ata-SAMSUNG_MZ7LN512HAJQ-000H1_S3TANA0KA01037`
- **Health**: 68% life remaining, SMART passed
- **Performance**: 93K IOPS random, 497 MiB/s sequential

## Filesystem Choice

**Decision**: Use **btrfs** with zstd compression for /home partition

**Rationale**:
- Consistent filesystem across all partitions
- Compression saves disk space for user files
- Snapshot capability for /home backups
- CoW benefits for data integrity
- Matches existing system configuration patterns

---

## Stage 1: Preparation and Backup
**Goal**: Ensure data safety before making any changes
**Success Criteria**: Backup of /home exists, current disk usage documented
**Status**: Not Started

### Tasks:
1. **Document current /home usage**
   ```bash
   # On raider host
   sudo du -sh /home/*
   sudo df -h /home
   ```

2. **Create backup of /home** (CRITICAL - DO NOT SKIP)
   ```bash
   # Option A: Backup to external drive or NAS
   rsync -avxHAX --progress /home/ /mnt/backup/raider-home-backup/

   # Option B: Create btrfs snapshot (quick, but on same disk)
   sudo btrfs subvolume snapshot /home /.snapshots/home-pre-migration
   ```

3. **Verify backup integrity**
   ```bash
   # Compare file counts
   find /home -type f | wc -l
   find /mnt/backup/raider-home-backup -type f | wc -l
   ```

---

## Stage 2: Update NixOS Configuration
**Goal**: Configure disko to use Samsung SSD for /home
**Success Criteria**: disko-config.nix includes Samsung SSD, builds successfully
**Status**: Not Started

### Tasks:
1. **Update disko-config.nix**
   - Add Samsung SSD as separate disk device
   - Configure single partition as btrfs with /home subvolume
   - Use compress=zstd and noatime mount options
   - Remove /home subvolume from NVMe btrfs config

2. **Build configuration locally**
   ```bash
   nix develop -c nix build .#nixosConfigurations.raider.config.system.build.toplevel
   ```

3. **Review generated systemd mount units**
   ```bash
   # Check what mounts will be created
   nix develop -c nix build .#nixosConfigurations.raider.config.system.build.toplevel
   ls -l result/etc/systemd/system/*.mount
   ```

---

## Stage 3: Deploy New Configuration (READ-ONLY MODE)
**Goal**: Deploy config but mount new /home as read-only first
**Success Criteria**: System boots with new disk mounted, old data still accessible
**Status**: Not Started

### Tasks:
1. **Deploy to raider**
   ```bash
   just deploy raider
   ```

2. **On raider host: Check new mount**
   ```bash
   # After boot, verify new disk is mounted
   lsblk
   mount | grep home
   ls -la /home  # Should be empty or minimal
   ```

3. **Verify old data still accessible via btrfs**
   ```bash
   # Mount old btrfs partition temporarily
   sudo mkdir -p /mnt/old-nvme
   sudo mount /dev/disk/by-id/nvme-XrayDisk_512GB_SSD_AA000000000000000321-part2 /mnt/old-nvme
   ls -la /mnt/old-nvme/home  # Should see old data
   ```

---

## Stage 4: Data Migration
**Goal**: Copy all data from old /home to new /home
**Success Criteria**: All files copied, permissions preserved, checksums verified
**Status**: Not Started

### Tasks:
1. **Boot into rescue mode or single-user mode**
   ```bash
   # Add to kernel parameters in bootloader:
   # systemd.unit=rescue.target
   ```

2. **Mount both old and new filesystems**
   ```bash
   # New /home should auto-mount at /home
   # Mount old btrfs /home subvolume
   sudo mkdir -p /mnt/old-home
   sudo mount -o subvol=/home /dev/disk/by-id/nvme-XrayDisk_512GB_SSD_AA000000000000000321-part2 /mnt/old-home
   ```

3. **Perform the migration**
   ```bash
   # Copy all data preserving attributes
   sudo rsync -avxHAX --progress /mnt/old-home/ /home/

   # Verify
   sudo du -sh /mnt/old-home
   sudo du -sh /home
   ```

4. **Fix permissions if needed**
   ```bash
   sudo chown -R arosenfeld:users /home/arosenfeld
   ```

---

## Stage 5: Testing and Validation
**Goal**: Ensure system works correctly with new /home
**Success Criteria**: User can login, access files, applications work
**Status**: Not Started

### Tasks:
1. **Reboot into normal mode**
   ```bash
   sudo systemctl reboot
   ```

2. **Login and verify**
   ```bash
   # Check home directory
   ls -la ~/

   # Verify important directories
   ls -la ~/.config
   ls -la ~/.local
   ls -la ~/Games  # Should still be symlink to /mnt/games

   # Check disk usage
   df -h /home
   ```

3. **Test applications**
   - Open GNOME Shell
   - Launch Steam/games
   - Check development tools
   - Verify Docker containers

4. **Monitor system logs**
   ```bash
   journalctl -b -p err  # Check for errors
   ```

---

## Stage 6: Cleanup
**Goal**: Remove old /home subvolume from btrfs
**Success Criteria**: NVMe space reclaimed, disko config finalized
**Status**: Not Started

### Tasks:
1. **Remove old btrfs /home subvolume**
   ```bash
   # Mount btrfs root
   sudo mount /dev/disk/by-id/nvme-XrayDisk_512GB_SSD_AA000000000000000321-part2 /mnt/old-nvme

   # Delete old /home subvolume
   sudo btrfs subvolume delete /mnt/old-nvme/home

   # Cleanup
   sudo umount /mnt/old-nvme
   ```

2. **Verify space reclaimed**
   ```bash
   df -h /
   ```

3. **Remove backup after confirming everything works**
   ```bash
   # Wait at least 1 week before removing backup
   # Verify system stability first
   ```

4. **Update documentation**
   - Update any references to disk layout
   - Document new configuration in commit message

---

## Rollback Plan

If anything goes wrong:

1. **Boot from NixOS live USB**
2. **Restore from backup**
   ```bash
   # Mount old btrfs partition
   mount /dev/disk/by-id/nvme-XrayDisk_512GB_SSD_AA000000000000000321-part2 /mnt

   # Restore backup to btrfs /home subvolume
   rsync -avxHAX /path/to/backup/ /mnt/home/
   ```
3. **Revert disko-config.nix** to previous version
4. **Rebuild and redeploy**

---

## Risk Assessment

- **Data Loss Risk**: MEDIUM (mitigated by backups)
- **Downtime Risk**: LOW (can rollback quickly)
- **Complexity**: MEDIUM (multiple stages, manual intervention needed)

## Critical Success Factors

1. ✅ **BACKUP FIRST** - Never skip backup stage
2. ✅ Test configuration builds before deploying
3. ✅ Perform migration in rescue/single-user mode
4. ✅ Verify data integrity after each stage
5. ✅ Keep old data until confirmed working (1+ week)

---

## Timeline Estimate

- Stage 1 (Backup): 1-2 hours (depends on /home size)
- Stage 2 (Config): 30 minutes
- Stage 3 (Deploy): 15 minutes
- Stage 4 (Migration): 1-2 hours
- Stage 5 (Testing): 1-2 hours
- Stage 6 (Cleanup): 30 minutes

**Total**: 4-7 hours
