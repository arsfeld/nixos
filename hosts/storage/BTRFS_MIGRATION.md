# BTRFS RAID1 Migration Guide

## Overview

This document describes the procedure for migrating the storage array from bcachefs to btrfs RAID1.

**⚠️ WARNING: This procedure will DESTROY all data on the storage array. Complete backups are MANDATORY.**

### Current State
- **Filesystem**: bcachefs (in read-only recovery mode)
- **Disks**: 6 disks (4 HDDs + 2 SSDs, ~42TB raw capacity)
- **Mount**: /mnt/storage
- **Status**: Read-only, experiencing filesystem corruption

### Target State
- **Filesystem**: btrfs RAID1
- **Disks**: 4 HDDs only (SSDs excluded - see Disk Inventory)
- **Capacity**: ~20TB usable (RAID1 = 2 copies)
- **Mount**: /mnt/storage
- **Features**: Compression (zstd), snapshots, scrubbing

## Disk Inventory

### HDDs Used in Array (4 disks)

| Device | Size | Model | WWN ID | Notes |
|--------|------|-------|---------|-------|
| sdc | 7.3T | WD HDD | wwn-0x5000cca0c2da52b1 | Bulk storage |
| sdd | 12.7T | Seagate HDD | wwn-0x5000c500e86c43b1 | Primary disk |
| sde | 12.7T | Seagate HDD | wwn-0x5000c500e987a4cc | Bulk storage |
| sdf | 7.3T | WD HDD | wwn-0x5000cca0becf6150 | Bulk storage |

**Total Raw**: ~40TB → **Usable with RAID1**: ~20TB

### SSDs Excluded from Array (2 disks)

| Device | Size | Model | WWN ID | Reason |
|--------|------|-------|---------|--------|
| sda | 476.9G | Samsung SSD | wwn-0x5002538d00c64e98 | Btrfs lacks tiered storage |
| sdb | 476.9G | Samsung SSD | wwn-0x5002538d098031e0 | Btrfs lacks tiered storage |

**Why SSDs are excluded**: Btrfs does not have native tiered storage or SSD caching like bcachefs. Including SSDs in the RAID1 array would waste their speed advantage on cold data that should remain on HDDs. The SSDs can be repurposed for other uses (VM storage, container volumes, etc.).

## Prerequisites

### 1. Backup Verification (CRITICAL)

Before proceeding, verify that ALL critical data is backed up to cloud storage:

```bash
# Check backup status
ssh storage.bat-boa.ts.net "systemctl status restic-backups-remote.service"

# Verify recent backup completion
ssh storage.bat-boa.ts.net "journalctl -u restic-backups-remote.service -n 50"

# Check backup repository
ssh cloud.bat-boa.ts.net "restic -r /var/backups/storage snapshots | tail -20"

# Verify specific critical directories are backed up
ssh cloud.bat-boa.ts.net "restic -r /var/backups/storage ls latest:/mnt/storage/homes"
```

**DO NOT PROCEED** unless backups are confirmed complete and recent (within 24 hours).

### 2. Service Shutdown

Stop all services that depend on /mnt/storage:

```bash
# On storage host
ssh storage.bat-boa.ts.net

# Stop podman containers
sudo systemctl stop podman-*

# Stop any other services using /mnt/storage
sudo systemctl stop caddy
sudo systemctl stop atticd

# Verify nothing is using /mnt/storage
sudo lsof +D /mnt/storage

# If anything shows up, investigate and stop those processes
```

### 3. Current Array Information

Document the current bcachefs array (all 6 devices for reference):

```bash
# Record current filesystem info for all devices
sudo bcachefs show-super /dev/sda  # SSD (will not be used in btrfs array)
sudo bcachefs show-super /dev/sdb  # SSD (will not be used in btrfs array)
sudo bcachefs show-super /dev/sdc  # HDD - will be used
sudo bcachefs show-super /dev/sdd  # HDD - will be used
sudo bcachefs show-super /dev/sde  # HDD - will be used
sudo bcachefs show-super /dev/sdf  # HDD - will be used

# Save to a file for reference
sudo bcachefs show-super /dev/sda > ~/bcachefs-migration-backup.txt
```

## Migration Procedure

### Phase 1: Preparation (On Storage Host)

1. **Boot into recovery mode** (optional but recommended):
   ```bash
   # If needed, boot from NixOS installer USB
   # Or use kexec to boot into installer
   ```

2. **Unmount the current array**:
   ```bash
   sudo umount /mnt/storage
   ```

3. **Verify disks are accessible**:
   ```bash
   lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT,UUID,MODEL
   ls -la /dev/disk/by-id/ | grep wwn-0x
   ```

### Phase 2: Disko Configuration (On Dev Machine)

1. **Enable the btrfs configuration**:

   Edit `/home/arosenfeld/Code/nixos/hosts/storage/configuration.nix`:

   ```nix
   imports = [
     ./disko-config-btrfs-raid1.nix  # Enable this line
     ./hardware-configuration.nix
     ./users.nix
     # ... other imports
   ];
   ```

   Then uncomment the configuration in `disko-config-btrfs-raid1.nix` by removing the `/*` and `*/` comment markers.

2. **Build the configuration**:
   ```bash
   nix develop -c just build storage
   ```

3. **If build succeeds**, prepare to deploy.

### Phase 3: Disk Initialization (On Storage Host)

**⚠️ POINT OF NO RETURN: This will destroy all data on the storage disks.**

If not using disko to format (manual approach):

```bash
# Wipe existing filesystem signatures (4 HDDs only)
sudo wipefs -af /dev/disk/by-id/wwn-0x5000c500e86c43b1  # Seagate 14TB #1
sudo wipefs -af /dev/disk/by-id/wwn-0x5000c500e987a4cc  # Seagate 14TB #2
sudo wipefs -af /dev/disk/by-id/wwn-0x5000cca0c2da52b1  # WD 8TB #1
sudo wipefs -af /dev/disk/by-id/wwn-0x5000cca0becf6150  # WD 8TB #2

# Create GPT partition table on each HDD
for disk in wwn-0x5000c500e86c43b1 wwn-0x5000c500e987a4cc wwn-0x5000cca0c2da52b1 wwn-0x5000cca0becf6150; do
  sudo parted /dev/disk/by-id/$disk mklabel gpt
  sudo parted /dev/disk/by-id/$disk mkpart primary 0% 100%
done
```

If using disko (automated approach):

```bash
# Disko will handle partitioning and formatting
sudo nix run github:nix-community/disko -- --mode disko /path/to/disko-config-btrfs-raid1.nix
```

### Phase 4: Deploy Configuration (On Dev Machine)

```bash
# Deploy the new configuration
# This will activate disko and create the btrfs filesystem
nix develop -c just deploy storage

# Or if deploying with reboot for safety
nix develop -c just boot storage
```

### Phase 5: Post-Deployment Setup (On Storage Host)

After the system reboots and mounts /mnt/storage:

1. **Verify initial filesystem**:
   ```bash
   sudo btrfs filesystem show /mnt/storage
   sudo btrfs filesystem df /mnt/storage
   ```

2. **Check RAID1 conversion** (if automated service ran):
   ```bash
   sudo systemctl status btrfs-raid-setup.service
   sudo btrfs filesystem df /mnt/storage
   # Should show Data: RAID1, Metadata: RAID1
   ```

3. **If RAID1 conversion didn't run automatically**, run it manually:
   ```bash
   # Add remaining 3 HDD disks (SSDs excluded)
   sudo btrfs device add -f /dev/disk/by-id/wwn-0x5000c500e987a4cc /mnt/storage  # Seagate 14TB #2
   sudo btrfs device add -f /dev/disk/by-id/wwn-0x5000cca0c2da52b1 /mnt/storage  # WD 8TB #1
   sudo btrfs device add -f /dev/disk/by-id/wwn-0x5000cca0becf6150 /mnt/storage  # WD 8TB #2

   # Convert to RAID1 (this may take several hours)
   sudo btrfs balance start -dconvert=raid1 -mconvert=raid1 /mnt/storage

   # Monitor progress (in another terminal)
   watch -n 5 'sudo btrfs balance status /mnt/storage'
   ```

### Phase 6: Data Restoration (On Storage Host)

1. **Restore from backup**:
   ```bash
   # From cloud host or restore directly on storage
   restic -r /path/to/backup restore latest --target /mnt/storage

   # Or via specific snapshot
   restic -r /path/to/backup snapshots
   restic -r /path/to/backup restore <snapshot-id> --target /mnt/storage
   ```

2. **Verify restoration**:
   ```bash
   ls -la /mnt/storage/
   df -h /mnt/storage
   ```

3. **Fix permissions if needed**:
   ```bash
   sudo chown -R user:group /mnt/storage/homes/user
   ```

### Phase 7: Service Restoration

1. **Start services**:
   ```bash
   sudo systemctl start podman-*
   sudo systemctl start caddy
   sudo systemctl start atticd
   ```

2. **Verify services**:
   ```bash
   sudo systemctl status podman-*
   curl https://attic.arsfeld.one/health
   ```

## Post-Migration Verification

### Filesystem Health Checks

```bash
# Verify RAID1 configuration
sudo btrfs filesystem show /mnt/storage
# Should show all 4 HDD devices

sudo btrfs filesystem df /mnt/storage
# Should show:
#   Data, RAID1: ...
#   System, RAID1: ...
#   Metadata, RAID1: ...

# Check filesystem usage
sudo btrfs filesystem usage /mnt/storage

# Run a scrub to verify data integrity
sudo btrfs scrub start /mnt/storage
sudo btrfs scrub status /mnt/storage
```

### Mount Verification

```bash
# Verify /home bind mount
ls -la /home
# Should show user directories

# Verify services can access storage
sudo systemctl status podman-plex
curl http://localhost:32400/web
```

### Performance Testing

```bash
# Test write performance
dd if=/dev/zero of=/mnt/storage/test bs=1M count=1000 oflag=direct
# Expected: ~200-300 MB/s for spinning disks

# Test read performance
dd if=/mnt/storage/test of=/dev/null bs=1M count=1000 iflag=direct

# Cleanup
rm /mnt/storage/test
```

## Rollback Strategy

### If Migration Fails Before Disk Wipe

1. Don't proceed with Phase 3
2. Restore the original configuration
3. Remount the bcachefs array in read-only mode
4. Investigate the issue

### If Migration Fails After Disk Wipe

**There is no rollback** - you must proceed with the btrfs setup or restore from backups.

This is why backup verification is CRITICAL in Prerequisites step 1.

### Recovery from Partial Failure

If RAID1 conversion fails midway:

```bash
# Check current state
sudo btrfs filesystem df /mnt/storage

# If some disks are missing
sudo btrfs device scan
sudo mount -o degraded /dev/disk/by-id/wwn-0x5000c500e86c43b1 /mnt/storage

# Add missing disks
sudo btrfs device add /dev/disk/by-id/wwn-0xXXXXXXXXXXXXXXXX /mnt/storage

# Resume balance
sudo btrfs balance resume /mnt/storage
```

## Maintenance After Migration

### Regular Scrubbing

Set up monthly scrubs to detect and repair bit rot:

```bash
# Add to systemd timer (consider adding this to NixOS config)
# Manual scrub command:
sudo btrfs scrub start /mnt/storage
```

### Monitoring

```bash
# Check RAID status
sudo btrfs device stats /mnt/storage

# Check space usage
sudo btrfs filesystem usage /mnt/storage

# List snapshots
sudo btrfs subvolume list /mnt/storage
```

### Snapshot Strategy

```bash
# Create manual snapshot before major changes
sudo btrfs subvolume snapshot /mnt/storage /mnt/storage/.snapshots/manual-$(date +%Y%m%d-%H%M%S)

# Delete old snapshots
sudo btrfs subvolume delete /mnt/storage/.snapshots/manual-20250101-120000
```

## Troubleshooting

### Issue: Device won't add to array

```bash
# Check if device has existing filesystem
sudo wipefs -a /dev/disk/by-id/wwn-0xXXXXXXXXXXXXXXXX

# Try adding again with force
sudo btrfs device add -f /dev/disk/by-id/wwn-0xXXXXXXXXXXXXXXXX /mnt/storage
```

### Issue: Balance operation stuck

```bash
# Check balance status
sudo btrfs balance status /mnt/storage

# Cancel if needed (not recommended unless necessary)
sudo btrfs balance cancel /mnt/storage

# Restart balance
sudo btrfs balance start -dconvert=raid1 -mconvert=raid1 /mnt/storage
```

### Issue: Out of space during balance

```bash
# Add more devices first if possible, or
# Delete some data to free up space
# Balance needs temporary space to reorganize data

# Check which chunks are allocated
sudo btrfs filesystem show /mnt/storage
sudo btrfs filesystem usage /mnt/storage
```

### Issue: Mount fails after reboot

```bash
# Try mounting in degraded mode
sudo mount -o degraded /dev/disk/by-label/storage-array /mnt/storage

# Check kernel messages
dmesg | grep btrfs

# Scan for devices
sudo btrfs device scan

# Try mounting again
sudo mount /mnt/storage
```

## Timeline Estimate

| Phase | Estimated Time | Can be Automated |
|-------|----------------|------------------|
| Backup verification | 30 minutes | Partial |
| Service shutdown | 15 minutes | Yes |
| Disk wipe & partition | 30 minutes | Yes (disko) |
| Initial filesystem creation | 5 minutes | Yes (disko) |
| Deploy & reboot | 10 minutes | Yes |
| RAID1 conversion (balance) | 4-8 hours | Yes |
| Data restoration | 6-12 hours | Yes |
| Service restoration | 30 minutes | Partial |
| Verification | 1 hour | Partial |

**Total estimated time**: 12-24 hours (mostly automated)

**Critical path**: RAID1 conversion and data restoration (can run overnight)

## References

- [Btrfs Wiki - Using with Multiple Devices](https://archive.kernel.org/oldwiki/btrfs.wiki.kernel.org/index.php/Using_Btrfs_with_Multiple_Devices.html)
- [NixOS Disko Documentation](https://github.com/nix-community/disko)
- [Btrfs RAID1 Best Practices](https://wiki.tnonline.net/w/Btrfs/Profiles)
- Task #94: Disable /mnt/storage mount (prerequisite)
- Task #101: This planning task
