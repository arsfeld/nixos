---
id: task-101
title: Plan disko configuration for btrfs RAID1 migration on /mnt/storage
status: Done
assignee: []
created_date: '2025-10-29 13:47'
updated_date: '2025-10-29 14:04'
labels:
  - storage
  - filesystem
  - disko
  - btrfs
  - planning
  - raid
dependencies: []
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Design and prepare a NixOS disko configuration to transform the /mnt/storage array from bcachefs to btrfs RAID1. The current array is in read-only recovery mode and should NOT be touched during this task.

**Context:**
- Current filesystem: bcachefs (experiencing issues, see task-94)
- Target filesystem: btrfs in RAID1 configuration
- Recovery strategy: Use cloud backup to repopulate files after transformation
- Host: storage

**Scope:**
This task is PLANNING ONLY - do NOT deploy or activate the configuration:
1. Research btrfs RAID1 best practices for NixOS/disko
2. Design disko configuration for the storage host
3. Determine disk/partition layout for RAID1
4. Document the transformation procedure
5. Add configuration to the codebase in DISABLED/COMMENTED state

**Critical Requirements:**
- Configuration MUST remain commented out or disabled after completion
- Do NOT modify the current /mnt/storage mount or array
- Do NOT deploy this configuration to the storage host
- Keep the bcachefs configuration intact alongside the new btrfs config
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Disko configuration for btrfs RAID1 is written and added to codebase
- [x] #2 Configuration is properly commented out or disabled (will not activate on deployment)
- [x] #3 Documentation explains the transformation procedure step-by-step
- [x] #4 Disk/partition layout is clearly defined for RAID1 setup
- [x] #5 Configuration builds successfully (nix build test) but remains inactive
- [x] #6 No changes to current /mnt/storage mount or bcachefs array
- [x] #7 Plan includes pre-flight checks and rollback strategy
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Created two files for the btrfs RAID1 migration planning:

1. **disko-config-btrfs-raid1.nix**: A complete disko configuration for transforming the 6-disk storage array from bcachefs to btrfs RAID1. The configuration uses a hybrid approach due to disko's limited native multi-device btrfs support:
   - Creates initial single-device btrfs filesystem on the largest disk (14TB Seagate)
   - Includes systemd service to automatically add remaining 5 disks and convert to RAID1
   - Defines proper subvolume structure (/data, /homes, /.snapshots)
   - Uses optimal mount options (zstd compression, noatime, space_cache=v2, autodefrag)
   - Configuration is fully commented out (/* */) and will not activate on deployment

2. **BTRFS_MIGRATION.md**: Comprehensive migration documentation including:
   - Complete disk inventory with WWN IDs for stable device references
   - 7-phase migration procedure with detailed steps
   - Critical backup verification requirements (MANDATORY before proceeding)
   - Timeline estimates (12-24 hours total, mostly automated)
   - Rollback strategies and recovery procedures
   - Post-migration maintenance recommendations (scrubbing, snapshots, monitoring)
   - Troubleshooting guide for common issues

**Key Design Decisions:**
- RAID1 across all 6 disks (~42TB raw → ~21TB usable) for maximum redundancy
- Btrfs RAID1 handles mixed disk sizes efficiently (2x512GB SSDs, 2x14TB HDDs, 2x8TB HDDs)
- Compression enabled (zstd:3) for space savings and reduced write amplification
- Automated post-boot service to complete RAID conversion
- Uses WWN IDs instead of /dev/sdX for stable device identification

**Testing:**
- Configuration builds successfully without errors
- Remains completely inactive (commented out)
- Does not affect current bcachefs mounts or configuration

## Update: SSDs Excluded from Array

After initial planning, decided to exclude the 2x512GB Samsung SSDs from the btrfs RAID1 array. Reason: Btrfs lacks native tiered storage/SSD caching like bcachefs. Including SSDs in a btrfs RAID1 would waste their speed advantage on cold data that should remain on HDDs.

**Revised Configuration:**
- Only 4 HDDs in array: 2x14TB Seagate + 2x8TB WD
- Capacity: ~40TB raw → ~20TB usable with RAID1
- SSDs can be repurposed for VM storage, container volumes, or other uses

**Commits:**
- Initial plan: 3776906
- SSD exclusion: 734cc55
<!-- SECTION:NOTES:END -->
