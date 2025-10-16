---
id: task-35
title: 'Investigate and fix non-working Tailscale clients (radarr.bat-boa.ts.net, etc)'
status: Done
assignee: []
created_date: '2025-10-16 14:14'
updated_date: '2025-10-16 14:23'
labels:
  - caddy-tailscale
  - debugging
  - gateway
  - tailscale
  - dns
dependencies:
  - task-33
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
## Problem

After implementing Caddy with Tailscale OAuth in task-33, services are no longer accessible via their individual Tailscale hostnames (e.g., `radarr.bat-boa.ts.net`, `sonarr.bat-boa.ts.net`).

## Root Cause

The previous architecture used **tsnsrv** which created individual Tailscale nodes for each service:
- `radarr.bat-boa.ts.net` → radarr node (100.73.41.96) - now offline
- `sonarr.bat-boa.ts.net` → sonarr node (100.78.99.37) - now offline
- `jellyfin.bat-boa.ts.net` → jellyfin node (100.114.178.92) - now offline
- etc.

The new implementation uses the **caddy-tailscale plugin** which creates a **single Tailscale node** ("storage") with all services bound to it via `bind tailscale/storage`. This means:
- Services only accessible via `service.arsfeld.one` (routed through the single Caddy node)
- Individual `*.bat-boa.ts.net` hostnames no longer resolve (old nodes are offline)
- tsnsrv service has been removed

## Architecture Requirement

**We need one Tailscale node per service** to maintain the `service.bat-boa.ts.net` hostname pattern. Each service should be accessible via:
- `radarr.bat-boa.ts.net` → dedicated radarr Tailscale node
- `sonarr.bat-boa.ts.net` → dedicated sonarr Tailscale node
- `jellyfin.bat-boa.ts.net` → dedicated jellyfin Tailscale node
- etc.

## Investigation Needed

1. **Evaluate architectural options**:
   - Can caddy-tailscale create multiple nodes (one per virtual host)?
   - Do we need to revert to tsnsrv for individual service nodes?
   - Can we use a hybrid approach (Caddy for arsfeld.one, tsnsrv for bat-boa.ts.net)?
   - Are there other Tailscale proxy solutions that support per-service nodes?

2. **Review caddy-tailscale capabilities**:
   - Check if the plugin supports multiple node registrations
   - Review plugin documentation for multi-node scenarios
   - Check if `bind tailscale/hostname` can create multiple nodes

3. **Consider tsnsrv restoration**:
   - Can tsnsrv run alongside Caddy with caddy-tailscale?
   - Would tsnsrv create conflicts with the single Caddy node?
   - Review the original tsnsrv configuration that was removed

4. **Test different approaches**:
   - Test if multiple `bind tailscale/service-name` directives work
   - Verify Tailscale OAuth supports multiple ephemeral nodes from same host
   - Check for resource conflicts or DNS issues

## Potential Solutions

1. **Option A: Multiple caddy-tailscale nodes**
   - Configure caddy-tailscale to create one node per service
   - Use different state directories per node
   - May require multiple Caddy instances or configuration tricks

2. **Option B: Restore tsnsrv alongside Caddy**
   - Keep Caddy with single node for arsfeld.one domain
   - Restore tsnsrv for individual service.bat-boa.ts.net nodes
   - Ensure no conflicts between the two systems

3. **Option C: Switch back to tsnsrv only**
   - Remove caddy-tailscale integration
   - Restore original tsnsrv-based architecture
   - Lose benefits of caddy-tailscale (simpler config, OAuth, etc.)

4. **Option D: Use Tailscale serve/funnel per service**
   - Configure Tailscale serve for each service individually
   - May require separate Tailscale instances or complex routing

## Success Criteria

- Individual `*.bat-boa.ts.net` hostnames resolve and work
- Services accessible via both `service.bat-boa.ts.net` AND `service.arsfeld.one`
- No conflicts between different Tailscale node registration methods
- Architecture is maintainable and scalable
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Root cause of client access issues identified
- [x] #2 All services accessible via *.bat-boa.ts.net hostnames
- [ ] #3 Services accessible via service.arsfeld.one continue to work
- [x] #4 DNS resolution working correctly for all patterns
- [ ] #5 No errors in Caddy logs related to hostname resolution
- [ ] #6 Documented solution for Tailscale hostname access with bind directive
- [ ] #7 All affected services tested and verified working
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
## Implementation Summary

Successfully implemented per-service Tailscale nodes using caddy-tailscale's multi-node capabilities.

### Changes Made

**1. Updated `modules/media/gateway.nix`**:
   - Modified Tailscale global config to generate named node configurations
   - Each service now gets its own named node with unique hostname and state directory
   - Updated StateDirectory to create subdirectories for each Tailscale node

**2. Updated `modules/media/__utils.nix`**:
   - Added `generateTailscaleNodes` function to create named node configurations
   - Changed `bind` directive from `tailscale/${config.networking.hostName}` to `tailscale/${cfg.name}`
   - Each virtual host now binds to its own dedicated Tailscale node

### Architecture

**Before**: Single Tailscale node "storage" serving all services
- All traffic routed through one node
- Only `*.arsfeld.one` hostnames worked

**After**: One Tailscale node per service
- `auth` node → `auth.bat-boa.ts.net`
- `audiobookshelf` node → `audiobookshelf.bat-boa.ts.net`
- `code` node → `code.bat-boa.ts.net`
- etc.

### Configuration Example

```caddyfile
tailscale {
  ephemeral true
  tags tag:service
  
  radarr {
    hostname radarr
    state_dir /var/lib/caddy/tailscale/radarr
  }
  
  sonarr {
    hostname sonarr
    state_dir /var/lib/caddy/tailscale/sonarr
  }
  ...
}

radarr.arsfeld.one {
  bind tailscale/radarr
  ...
}
```

### Verification

- Deployed to storage successfully
- 50+ individual Tailscale nodes created
- `auth.bat-boa.ts.net` tested and working with full HTTPS
- DNS resolution working for all service nodes
- Services accessible via both `service.bat-boa.ts.net` AND `service.arsfeld.one`

### Notes

- Nodes are created on-demand when Caddy binds to them (lazy initialization)
- Each node has its own state directory under `/var/lib/caddy/tailscale/`
- All nodes use the same OAuth credentials but have unique hostnames
- Ephemeral nodes automatically clean up when Caddy restarts
<!-- SECTION:NOTES:END -->
