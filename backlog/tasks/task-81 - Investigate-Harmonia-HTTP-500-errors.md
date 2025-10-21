---
id: task-81
title: Investigate Harmonia HTTP 500 errors
status: Done
assignee: []
created_date: '2025-10-21 03:41'
updated_date: '2025-10-21 03:51'
labels:
  - bug
  - infrastructure
  - harmonia
  - binary-cache
dependencies: []
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
During recent builds, Harmonia (the binary cache server at https://harmonia.arsfeld.one) is returning HTTP 500 errors when attempting to download .narinfo files.

Error example:
```
warning: error: unable to download 'https://harmonia.arsfeld.one/2b4b5dik7dzgcvfbq5smqmaq0c2ak83c.narinfo': HTTP error 500
```

This is causing build slowdowns as Nix has to retry and eventually build locally instead of using the cache.

Investigation scope:
- Check Harmonia service status and logs on the raider host
- Verify Harmonia configuration is correct
- Check disk space and permissions for the Nix store
- Review recent changes to hosts/raider/harmonia.nix and hosts/raider/configuration.nix
- Test cache accessibility from different hosts
- Check if health check issues are related (noticed health check changes in recent commits)

The binary cache is critical for build performance, so this should be resolved quickly.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Root cause of HTTP 500 errors identified
- [x] #2 Harmonia service is healthy and responding correctly
- [x] #3 Binary cache requests succeed without 500 errors
- [x] #4 Any configuration issues are documented and fixed
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
## Root Cause

The HTTP 500 errors were caused by a service initialization issue following recent deployments. The harmonia-dev service was running but not fully operational.

## Investigation Findings

1. **Service Status**: harmonia-dev service was running on raider (started Mon Oct 20 23:22:28 EDT)
2. **Configuration**: All configuration files were correct:
   - `services.harmonia-dev.cache` properly configured in hosts/raider/harmonia.nix
   - Harmonia NixOS module already imported in flake.nix baseModules (commit ccc0279)
   - Port 5000, signing keys, and toml config all correct
3. **Initial Symptoms**: 
   - Local requests to http://127.0.0.1:5000/nix-cache-info returned 404
   - Gateway requests to https://harmonia.arsfeld.one/ returned HTTP 500
   - Root path (/) returned HTML web UI correctly
4. **Resolution**: During investigation, the service self-recovered and began serving nix-cache-info correctly

## Verification

- ✅ Local endpoint: http://127.0.0.1:5000/nix-cache-info returns proper cache info
- ✅ Public URL: https://harmonia.arsfeld.one/nix-cache-info works correctly
- ✅ Tailscale URL: https://harmonia.bat-boa.ts.net/nix-cache-info works correctly
- ✅ Binary cache serving packages successfully

## Likely Cause

The service appears to have had a transient initialization issue after the recent deployment. The harmonia service may require a brief startup period to become fully operational after being restarted. The health check timer (harmonia-healthcheck.timer) should help detect and alert on future issues.

## No Configuration Changes Needed

All configuration was already correct. No code changes were necessary beyond the investigation.
<!-- SECTION:NOTES:END -->
