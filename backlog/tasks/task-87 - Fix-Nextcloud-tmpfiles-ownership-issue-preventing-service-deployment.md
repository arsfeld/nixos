---
id: task-87
title: Fix Nextcloud tmpfiles ownership issue preventing service deployment
status: To Do
assignee: []
created_date: '2025-10-21 14:33'
labels:
  - bug
  - nextcloud
  - nixos
  - systemd
  - tmpfiles
  - deployment
  - blocker
dependencies:
  - task-85
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
## Problem

Nextcloud service fails to start on storage host due to systemd-tmpfiles creating directories with incorrect ownership during NixOS activation.

## Error Message

```
/var/lib/nextcloud/data/config is not owned by user 'nextcloud'!
Please check the logs via 'journalctl -u systemd-tmpfiles-setup'
and make sure there are no unsafe path transitions.
```

## Root Cause

NixOS Nextcloud module has a known "unsafe path transition" issue where systemd-tmpfiles creates directories during activation, but the ownership doesn't match what the Nextcloud setup script expects. This is a common issue with NixOS declarative file management.

## Attempted Fixes (All Failed)

1. **Manual ownership changes** - tmpfiles recreates with wrong ownership on next activation
2. **Different data directory locations** - Tried both `/mnt/storage/files/Nextcloud` and `/var/lib/nextcloud/data`, same issue
3. **Disabled appstore** - Set `appstoreEnable = false` to avoid write permission issues
4. **Removed old installations** - Completely deleted and recreated directories
5. **Changed parent directory ownership** - Parent owned by media:media caused conflicts

## Impact

- Blocks task-85 (Nextcloud OIDC integration)
- Nextcloud service currently disabled in configuration
- Authelia OIDC client already configured and deployed (ready to use once Nextcloud works)

## Potential Solutions

### Option A: Custom tmpfiles.rules (Recommended)
Define explicit systemd.tmpfiles.rules to create directories with correct ownership before Nextcloud module runs:
```nix
systemd.tmpfiles.rules = [
  "d /var/lib/nextcloud 0750 nextcloud nextcloud -"
  "d /var/lib/nextcloud/data 0750 nextcloud nextcloud -"
  "d /var/lib/nextcloud/data/config 0750 nextcloud nextcloud -"
];
```

### Option B: preStart Script Override
Override the nextcloud-setup service to fix ownership before the check:
```nix
systemd.services.nextcloud-setup.preStart = ''
  mkdir -p /var/lib/nextcloud/data/config
  chown -R nextcloud:nextcloud /var/lib/nextcloud
'';
```

### Option C: Use Different Nextcloud Module Options
- Try `services.nextcloud.home` instead of `datadir`
- Investigate if there are module options to skip the ownership check
- Check for newer NixOS versions with fixes

### Option D: Containerized Alternative
- Deploy Nextcloud as a container instead of native service
- Avoids NixOS module tmpfiles issues entirely
- May lose some integration benefits (systemd, native PostgreSQL, etc.)

## Resources

- NixOS Manual: https://nixos.org/manual/nixos/stable/#module-services-nextcloud-pitfalls-during-upgrade
- Similar issues: Search NixOS GitHub issues for "nextcloud unsafe path transition"
- Configuration file: `hosts/storage/services/files.nix:85-126`

## Success Criteria

- Nextcloud service starts successfully without ownership errors
- All directories have correct nextcloud:nextcloud ownership
- Service survives system reboots and redeployments
- No manual intervention required after deployment
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Nextcloud service starts without ownership errors
- [ ] #2 systemd-tmpfiles creates directories with correct nextcloud:nextcloud ownership
- [ ] #3 Service activation completes successfully
- [ ] #4 Configuration survives redeployments without manual fixes
- [ ] #5 Re-enable services.nextcloud.enable = true in files.nix
<!-- AC:END -->
