---
id: task-57
title: Fix immich systemd-tmpfiles unsafe path transition error
status: Done
assignee:
  - '@claude'
created_date: '2025-10-17 15:15'
updated_date: '2025-10-17 15:41'
labels:
  - bug
  - immich
  - systemd
  - storage
dependencies: []
priority: medium
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
systemd-tmpfiles is detecting an unsafe path transition for the immich storage directory:

```
Oct 17 11:13:57 storage systemd-tmpfiles[3119902]: Detected unsafe path transition /mnt/storage/files (owned by media) → /mnt/storage/files/Immich
```

The issue is that `/mnt/storage/files` is owned by the `media` user, but the subdirectory for Immich has different ownership, which systemd considers a security risk.

**Investigation needed:**
- Check current ownership of `/mnt/storage/files/Immich`
- Determine correct ownership for immich service
- Review tmpfiles.d configuration for immich
- Check if this is related to the constellation media module configuration

**Possible solutions:**
1. Ensure consistent ownership throughout the path
2. Update tmpfiles.d configuration to use correct user/group
3. Adjust directory permissions in the immich service configuration
<!-- SECTION:DESCRIPTION:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
## Solution

The unsafe path transition warning occurred because:
1. The parent directory `/mnt/storage/files` is owned by `media:media` (UID/GID 5000)
2. The immich service was running as the default `immich` user and group
3. systemd-tmpfiles detected the ownership change as a security risk

Fixed by configuring the immich service to run as the `media` user and group, ensuring consistent ownership throughout the directory path.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
## Implementation

Modified `/home/arosenfeld/Projects/nixos/hosts/storage/services/immich.nix` to add:
```nix
user = vars.user;
group = vars.group;
```

This configures immich to run as the media user (defined in media.config), which owns the parent directory. The tmpfiles.d configuration will now set `/mnt/storage/files/Immich` to be owned by `media:media`, matching the parent directory ownership.

Build verified successfully with no errors.

## Final Fix

The original fix resolved the tmpfiles warning but broke PostgreSQL authentication. Additional changes were needed:

1. Added PostgreSQL ident map to allow `media` system user to connect as `immich` database user
2. Manually updated `/var/lib/postgresql/16/pg_ident.conf` and `/var/lib/postgresql/16/pg_hba.conf` (NixOS doesn't manage these after initial creation)
3. Fixed ownership of `/mnt/storage/files/Immich` directory to `media:media`

Immich is now running successfully with no errors.
<!-- SECTION:NOTES:END -->
