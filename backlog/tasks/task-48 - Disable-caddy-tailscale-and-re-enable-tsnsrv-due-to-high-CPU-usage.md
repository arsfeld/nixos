---
id: task-48
title: Disable caddy-tailscale and re-enable tsnsrv due to high CPU usage
status: To Do
assignee: []
created_date: '2025-10-16 18:41'
updated_date: '2025-10-16 18:47'
labels:
  - performance
  - caddy
  - tailscale
  - tsnsrv
  - cpu
dependencies: []
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
## Problem

Both caddy-tailscale and the storage host are experiencing high CPU usage with the current caddy-tailscale implementation. Additionally, TLS certificate provisioning is not working (see task-47).

## Context

- Previously used tsnsrv for Tailscale service exposure
- Switched to caddy-tailscale to have individual *.bat-boa.ts.net nodes per service
- However, this is causing performance issues and TLS certificates are not provisioning correctly

## Solution

Revert to tsnsrv until the caddy-tailscale certificate issues are resolved:

1. Set `exposeViaTailscale = false` for all services in media configuration
2. Verify tsnsrv configuration is still in place
3. Re-enable/verify tsnsrv is running on storage host
4. Test service access via tsnsrv
5. Monitor CPU usage to confirm improvement

## Configuration Changes

In the media services configuration, change all services from:
```nix
exposeViaTailscale = true;
```

To:
```nix
exposeViaTailscale = false;
```

This will:
- Stop Caddy from creating individual Tailscale nodes per service
- Reduce CPU overhead from multiple tsnet instances
- Fall back to tsnsrv for Tailscale access

## Verification

After changes:
- Verify services are accessible via Tailscale
- Check CPU usage on storage host
- Confirm Caddy CPU usage has normalized
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 caddy-tailscale disabled (all services have exposeViaTailscale = false)
- [x] #2 tsnsrv is running and serving services
- [ ] #3 All media services accessible via Tailscale through tsnsrv
- [ ] #4 CPU usage on storage host has decreased significantly
- [ ] #5 Caddy CPU usage has normalized
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
## Implementation Complete

### Changes Made

1. **Emptied tailscaleExposed array** in `modules/constellation/services.nix`:
   - Set `tailscaleExposed = []` to disable caddy-tailscale for all services
   - All services now have `exposeViaTailscale = false`

2. **Re-enabled tsnsrv** in `hosts/storage/services/misc.nix`:
   - Changed `services.tsnsrv.enable = false` to `services.tsnsrv.enable = true`
   - Added full tsnsrv configuration with defaults (authKeyPath, ephemeral, prometheusAddr)

3. **Re-added tsnsrv services configuration** in `modules/media/gateway.nix`:
   - Added `services.tsnsrv.services = utils.generateTsnsrvConfigs { services = cfg.services; };`
   - This automatically generates tsnsrv service configurations from media gateway services

4. **Deployed successfully to storage host**:
   - Build completed successfully
   - tsnsrv-all.service started
   - Caddy reconfigured without Tailscale nodes

### Next Steps

- [ ] Test service access via Tailscale (e.g., https://jellyfin.bat-boa.ts.net)
- [ ] Monitor CPU usage on storage host over next 24-48 hours
- [ ] Monitor Caddy CPU usage to confirm it has normalized

### Files Modified

- `modules/constellation/services.nix` (tailscaleExposed array emptied)
- `hosts/storage/services/misc.nix` (tsnsrv re-enabled)
- `modules/media/gateway.nix` (tsnsrv services configuration re-added)
<!-- SECTION:NOTES:END -->
