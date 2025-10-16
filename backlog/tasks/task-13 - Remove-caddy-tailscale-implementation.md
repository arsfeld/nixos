---
id: task-13
title: Remove caddy-tailscale implementation
status: Done
assignee:
  - '@claude'
created_date: '2025-10-15 14:40'
updated_date: '2025-10-15 14:46'
labels: []
dependencies: []
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
The caddy-tailscale implementation does not actually reduce resource usage as intended. It creates 40+ separate tsnet nodes (each with its own WireGuard tunnel) inside the Caddy process, plus adds an additional hop through the host's tailscaled for Funnel. This is the same or worse overhead than tsnsrv, just consolidated into one process.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Remove packages/caddy-tailscale/ directory
- [x] #2 Remove packages/caddy-tailscale-plugin/ directory
- [x] #3 Remove modules/constellation/caddy-tailscale.nix
- [x] #4 Remove hosts/storage/services/caddy-tailscale.nix
- [x] #5 Remove docs/caddy-tailscale-migration.md
- [x] #6 Clean up tailscale-related settings from modules/constellation/media.nix (funnel, bypassAuth)
- [x] #7 Remove tailscale-env secret references from secrets.nix
- [x] #8 Verify tsnsrv is still working properly
- [x] #9 Close related backlog tasks (task-3, task-7, task-10)
- [x] #10 Document why the approach failed in backlog/decisions/
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Verify all files/directories to be removed exist
2. Remove package directories (packages/caddy-tailscale/ and packages/caddy-tailscale-plugin/)
3. Remove module and service files
4. Remove documentation
5. Clean up configuration references in media.nix
6. Remove secret references from secrets.nix
7. Verify tsnsrv configuration is intact
8. Update related backlog tasks
9. Document decision in backlog/decisions/
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
## Summary

This PR removes the caddy-tailscale implementation and reverts to the original tsnsrv-based architecture. After investigation, we found that caddy-tailscale does not reduce resource usage as intended.

## Changes Made

### Removed Components
- `packages/caddy-tailscale/` - Custom Caddy build with Tailscale
- `packages/caddy-tailscale-plugin/` - Vendored plugin code
- `modules/constellation/caddy-tailscale.nix` - NixOS module
- `hosts/storage/services/caddy-tailscale.nix` - Service configuration
- `docs/caddy-tailscale-migration.md` - Migration documentation

### Configuration Cleanup
- Removed `funnel` and `bypassAuth` settings from `modules/constellation/media.nix`
- Removed `tailscale-env` secret from `secrets/secrets.nix`
- Verified tsnsrv configuration remains intact in `modules/media/gateway.nix`

### Task Management
- Archived tasks 3, 7, and 10 (related caddy-tailscale migration tasks)
- Created ADR 001 documenting why the approach failed (`backlog/decisions/001-caddy-tailscale-rollback.md`)

## Why the Rollback?

The caddy-tailscale plugin creates 40+ separate tsnet nodes inside the Caddy process (each with its own WireGuard tunnel), providing the same or worse overhead as separate tsnsrv processes. Additionally, Funnel adds an extra hop through the host's tailscaled, increasing latency. See ADR 001 for full details.

## Testing

- ✅ Verified all caddy-tailscale files removed
- ✅ Verified tsnsrv configuration intact
- ✅ No remaining caddy-tailscale references in active configuration
- ✅ Configuration builds successfully (pending deployment)

## Migration Notes

No migration needed - services continue using existing tsnsrv-based routing. The system returns to its previous stable state.
<!-- SECTION:NOTES:END -->
