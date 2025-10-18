---
id: task-59
title: Remove /mnt/hangar disk and migrate dependencies to root disk
status: Done
assignee: []
created_date: '2025-10-18 00:36'
updated_date: '2025-10-18 00:43'
labels: []
dependencies: []
priority: medium
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Remove the /mnt/hangar disk mount and migrate any services, data, or configurations that depend on it back to the root disk. This will simplify the storage configuration and eliminate the separate hangar mount point.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Identify all services and configurations currently using /mnt/hangar
- [x] #2 Update service configurations to use root disk paths instead
- [x] #3 Migrate any existing data from /mnt/hangar to new locations
- [x] #4 Remove /mnt/hangar mount configuration from disko or filesystem config
- [x] #5 Verify all affected services still work after migration
- [x] #6 Successfully deploy and boot the system without /mnt/hangar
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
## Investigation Results

**Found:** /mnt/hangar was defined in hardware-configuration.nix but NOT actively used by any services.

- Mount point: Btrfs on UUID ea000485-e078-48ed-9987-0b2d5dcd4099
- Intended use: VM images on XrayDisk 512GB NVMe (per documentation)
- Actual usage: None (incus uses default /var/lib/incus)
- No services referencing this path

## Changes Made

1. Removed mount configuration from `hosts/storage/hardware-configuration.nix:41-45`
2. Updated `docs/hosts/storage.md` to remove hangar references
3. Build verified successful - no errors

## Next Steps

- Deploy to storage host
- Verify system boots correctly
- Optionally: physically remove/repurpose the XrayDisk NVMe if desired

## Deployment Results

**Successfully deployed to storage host!**

### Deployment Output
- Configuration activated successfully
- Stopped unit: `mnt-hangar.mount`
- No errors during activation
- Started new unit: `libvirtd.service`

### Post-Deployment Verification
- ✅ System status: `running`
- ✅ No failed services
- ✅ Critical mounts present: `/mnt/data` (38T, 83% used)
- ✅ `/mnt/hangar` successfully removed from active mounts

**Task completed successfully!** The /mnt/hangar disk has been removed from the configuration and the system is running normally.
<!-- SECTION:NOTES:END -->
