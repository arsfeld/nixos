# Implementation Plan: Raider NVMe Migration (Simplified)

**Task**: Migrate raider from SSD 850 EVO to NVMe XrayDisk (task-65)
**Approach**: Fresh NixOS install on NVMe, only migrate /home user data

## Stage 1: Pre-flight Checks and Preparation
**Goal**: Verify system state and prepare for migration
**Success Criteria**:
- Current disk layout is documented
- NVMe drive is visible and identified correctly
- Current /home size is known and fits on new drive
- Disko config is verified

**Tests**:
- `lsblk` shows both drives
- `/dev/disk/by-id/nvme-XrayDisk_512GB_SSD_AA000000000000000321` exists
- /home size is under 512GB

**Status**: Not Started

## Stage 2: Partition and Format NVMe with Disko
**Goal**: Use disko to create partition layout on NVMe
**Success Criteria**:
- NVMe is partitioned with GPT (ESP + root)
- Btrfs filesystem created with subvolumes (/root, /home, /nix, /var/log, /tmp)
- Filesystems are formatted and mounted

**Tests**:
- `lsblk /dev/nvme1n1` shows 2 partitions
- `sudo btrfs subvolume list /mnt` shows 5 subvolumes
- /mnt, /mnt/home, /mnt/nix, /mnt/boot are mounted

**Status**: Not Started

## Stage 3: Copy /home Data
**Goal**: Safely copy all /home data to new NVMe /home subvolume
**Success Criteria**:
- All files from /home copied to new drive
- Permissions and ownership preserved
- Verification shows no data loss

**Tests**:
- File count matches: `find /home -type f | wc -l` vs `find /mnt/home -type f | wc -l`
- Critical files exist in /mnt/home/arosenfeld/
- Disk usage matches expected

**Status**: Not Started

## Stage 4: Install NixOS on NVMe
**Goal**: Install NixOS system on the new NVMe drive
**Success Criteria**:
- NixOS installed to /mnt using flake configuration
- Bootloader (systemd-boot) installed
- Installation completes without errors

**Tests**:
- `nixos-install` exits successfully
- /mnt/boot has systemd-boot files
- /mnt/etc/nixos contains configuration

**Status**: Not Started

## Stage 5: Boot from NVMe and Verify
**Goal**: Boot system from NVMe and verify everything works
**Success Criteria**:
- System boots from NVMe successfully
- User can login
- /home data is accessible and intact
- /mnt/games is still mounted and accessible

**Tests**:
- `lsblk` shows root on nvme1n1p2
- User arosenfeld can login
- /home/arosenfeld files are intact
- `df -h | grep games` shows /mnt/games mounted

**Status**: Not Started

## Stage 6: Cleanup
**Goal**: Clean up old references and finalize
**Success Criteria**:
- System is running normally from NVMe
- Old SSD decision made (keep as backup, repurpose, or remove)
- Documentation updated

**Tests**:
- System stable for at least one full boot cycle
- No errors in `journalctl -b`

**Status**: Not Started

## Current State
- **Source Drive**: Samsung SSD 850 EVO 1TB (/dev/sda)
- **Target Drive**: XrayDisk 512GB NVMe (/dev/nvme1n1)
- **Migration Scope**: /home only - everything else rebuilt fresh
- **Disko Config**: Already configured at `hosts/raider/disko-config.nix`

## Safety Notes
1. Old SSD remains intact - can boot from it if NVMe fails
2. Only /home is critical user data - everything else is declarative
3. /mnt/games partition (on different drive) is unaffected
4. Can rebuild NixOS as many times as needed without data loss
