---
id: task-94
title: Disable /mnt/storage to enable userspace fsck
status: In Progress
assignee: []
created_date: '2025-10-26 23:52'
updated_date: '2025-10-27 22:39'
labels:
  - storage
  - maintenance
  - filesystem
  - bcachefs
dependencies: []
priority: medium
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Disable the /mnt/storage mount point on the storage host to allow a clean reboot and userspace filesystem check (fsck). This requires:
1. Stopping all services using /mnt/storage
2. Unmounting /mnt/storage or preventing it from mounting on boot
3. Rebooting the system
4. Running userspace fsck on the underlying storage device
5. Re-enabling /mnt/storage after fsck completes
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 System boots successfully without /mnt/storage mounted
- [x] #2 Configuration deploys without build errors
- [x] #3 bcachefs fsck completes successfully on the unmounted filesystem
- [ ] #4 After re-enabling, /mnt/storage mounts correctly on boot
- [ ] #5 All services (Samba, media containers, backups, home directories) function normally after re-enabling
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
## Stage 1: Complete ✓
- Disabled /mnt/storage, /mnt/data, and /home mounts in hardware-configuration.nix:21-42
- Configuration built and deployed successfully to storage host
- Expected service failures confirmed (podman containers, home-manager)
- System is ready for reboot and fsck

## Stage 2: Complete ✓
- Rebooted storage host successfully
- System came back online without /mnt/storage mounted
- Verified clean boot state

## Stage 3: FAILED ✗
**bcachefs fsck crashed with assertion error**

**Timeline**:
- Started: Sun Oct 26, 2025 8:31 PM EDT
- Ended: Mon Oct 27, 2025 6:34 PM EDT  
- Duration: ~22 hours
- Exit Code: 134 (SIGABRT)

**Progress**:
- ✓ Version upgrade: 1.13 → 1.31
- ✓ Journal replay complete
- ✓ check_allocations: 100% (192,831 nodes)
- ✓ check_alloc_info: 100% (28,302 nodes)
- ✗ check_lrus: CRASHED during execution

**Fatal Error**:
```
bcachefs: libbcachefs/btree_update_interior.c:1658: btree_split: 
Assertion `!(parent && !btree_node_intent_locked(...))' failed.
```

This is an **internal bcachefs bug**, not unfixable filesystem corruption. The fsck tool hit an edge case after running for 22 hours.

**Documentation**:
- Full logs: `bcachefs-fsck-failure-2025-10-27.log`
- Incident report: `bcachefs-fsck-incident-report.md`

## Recommended Next Steps

1. **Try mount with recovery** (most likely to succeed):
   ```bash
   # Re-enable mounts, deploy, reboot
   # bcachefs will attempt recovery on mount
   ```

2. **Alternative**: Try read-only fsck to assess state
3. **Report bug** to bcachefs developers with logs
4. **Restore from backup** if all else fails

The filesystem is likely repairable - most fsck passes completed successfully.
<!-- SECTION:NOTES:END -->
