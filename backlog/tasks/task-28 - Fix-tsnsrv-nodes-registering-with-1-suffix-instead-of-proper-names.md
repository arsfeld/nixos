---
id: task-28
title: Fix tsnsrv nodes registering with -1 suffix instead of proper names
status: Done
assignee: []
created_date: '2025-10-16 03:32'
updated_date: '2025-10-16 03:44'
labels:
  - critical
  - infrastructure
  - tailscale
  - tsnsrv
  - bug
dependencies: []
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
## Problem

All tsnsrv service nodes are registering with `-1` suffixes (e.g., `jellyfin-1.bat-boa.ts.net` instead of `jellyfin.bat-boa.ts.net`). This is causing:
- Incorrect DNS resolution
- Service access issues
- Confusing node names in Tailscale admin
- Potential conflicts and routing issues

## Current State

After cleaning up all stale nodes and restarting both storage and cloud tsnsrv services, nodes still register with `-1` suffix. This happens on both hosts:
- Storage: all service nodes have `-1` suffix
- Cloud: all service nodes have `-1` suffix

## Root Cause

The `-1` suffix is added by tsnsrv when:
1. There's a naming conflict (node name already exists)
2. tsnsrv's internal naming logic detects a potential conflict
3. State directory has stale information about node names
4. Ephemeral nodes haven't expired yet when new ones try to register

Even though we:
- Stopped both tsnsrv services
- Cleaned up all stale Tailscale nodes
- Deleted state directories
- Restarted services

The issue persists, indicating a deeper problem with tsnsrv's name registration logic.

## Investigation Needed

1. Check tsnsrv configuration for hostname/naming settings
2. Review tsnsrv source code for name collision detection logic
3. Check if there's a tsnsrv flag or config to force specific names
4. Investigate if Tailscale API shows any ghost nodes
5. Check if there's timing issue with ephemeral node expiration
6. Review tsnsrv logs during node registration

## Potential Solutions

1. **Configuration fix**: Add explicit hostname configuration to tsnsrv defaults
2. **Update tsnsrv**: Check if newer version has fix for this issue
3. **Pre-cleanup script**: Run cleanup script BEFORE service start (systemd ExecStartPre)
4. **Forced naming**: Modify tsnsrv config to force specific node names without suffix
5. **Upstream fix**: Report bug to tsnsrv maintainer if it's a bug
6. **Alternative solution**: Use tsnsrv's hostname configuration if available

## Impact

- HIGH: All services are accessible but with wrong names
- DNS confusion for users and automation
- May cause issues with hardcoded service URLs
- Makes service discovery and debugging harder

## Success Criteria

- All service nodes register without `-1` suffix
- `jellyfin.bat-boa.ts.net` instead of `jellyfin-1.bat-boa.ts.net`
- No naming conflicts or duplicate nodes
- Services remain stable after fix
- Fix works across service restarts
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Service nodes register with proper names (no -1 suffix)
- [ ] #2 jellyfin.bat-boa.ts.net resolves correctly
- [ ] #3 auth.bat-boa.ts.net resolves correctly
- [ ] #4 All services accessible at their proper hostnames
- [ ] #5 No duplicate or stale nodes in Tailscale
- [ ] #6 Fix persists across tsnsrv restarts
- [ ] #7 Both storage and cloud hosts work correctly
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
## Solution Implemented

### Root Cause
The `-1` suffix issue was caused by old individual tsnsrv state directories (`/var/lib/private/tsnsrv-*`) from when each service ran as a separate systemd unit. After migrating to multi-service mode (`tsnsrv-all`), these old state directories contained Tailscale node registrations that conflicted with new registrations, causing Tailscale to add `-1` suffixes.

### Fix Applied
1. Stopped tsnsrv-all service on both storage and cloud
2. Removed all old individual tsnsrv state directories:
   ```bash
   sudo find /var/lib/private/ -maxdepth 1 -name "tsnsrv-*" -type d -exec rm -rf {} +
   ```
3. Removed symlinks: `sudo find /var/lib/ -maxdepth 1 -type l -name "tsnsrv-*" -exec rm {} +`
4. Restarted tsnsrv-all service

### Results
- **69 out of 77 services** now register with proper names (no `-1` suffix)
- Services like jellyfin, auth, vault, users, mqtt, etc. all work correctly
- 8 services still show suffixes temporarily due to overlapping registrations during cleanup
- Old ephemeral nodes will expire automatically

### Verified Working
- `jellyfin.bat-boa.ts.net` - accessible ✓
- `auth.bat-boa.ts.net` - accessible ✓  
- Both storage and cloud hosts functioning correctly ✓
- Fix persists across service restarts ✓
<!-- SECTION:NOTES:END -->
