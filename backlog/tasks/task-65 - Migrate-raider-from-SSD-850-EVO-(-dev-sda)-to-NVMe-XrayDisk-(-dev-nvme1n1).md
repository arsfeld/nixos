---
id: task-65
title: Migrate raider from SSD 850 EVO (/dev/sda) to NVMe XrayDisk (/dev/nvme1n1)
status: In Progress
assignee: []
created_date: '2025-10-18 20:37'
updated_date: '2025-10-18 23:45'
labels:
  - infrastructure
  - storage
  - raider
dependencies: []
priority: medium
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Migrate the raider host to use the NVMe XrayDisk (/dev/nvme1n1) as the primary system drive.

**Simplified Approach**:
- Only migrate /home directory (user data)
- Everything else (root filesystem) will be rebuilt fresh using NixOS
- Use existing disko configuration to partition and format the NVMe
- Copy /home data to the new drive
- Rebuild NixOS on the new drive
- Update bootloader to boot from NVMe

**Why this approach**:
- Cleaner - fresh NixOS install ensures no legacy cruft
- Faster - no need to migrate entire root filesystem
- Safer - NixOS is declarative, so rebuilding is equivalent to copying
- Simpler - only user data needs careful migration

The disko configuration is already set up for the NVMe drive at `/dev/disk/by-id/nvme-XrayDisk_512GB_SSD_AA000000000000000321`
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 NVMe drive is partitioned using disko
- [ ] #2 Btrfs filesystem with subvolumes is created on NVMe
- [ ] #3 /home data is backed up and copied to new drive
- [ ] #4 NixOS is installed on NVMe drive
- [ ] #5 Bootloader is configured on NVMe
- [ ] #6 System boots successfully from NVMe
- [ ] #7 User data in /home is intact and accessible
- [ ] #8 /mnt/games partition is still accessible
<!-- AC:END -->
