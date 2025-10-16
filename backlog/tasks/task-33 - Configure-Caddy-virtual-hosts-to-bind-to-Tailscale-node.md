---
id: task-33
title: Configure Caddy virtual hosts to bind to Tailscale node
status: Done
assignee: []
created_date: '2025-10-16 14:03'
updated_date: '2025-10-16 14:11'
labels:
  - caddy-tailscale
  - oauth
  - gateway
  - tailscale
dependencies: []
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
## Problem

The caddy-tailscale plugin is successfully compiled and loaded, but no Tailscale nodes are being created because:

**Nodes are created lazily** - only when virtual hosts explicitly bind to `tailscale/nodename`

Currently, our virtual hosts bind to `:443` (regular listener), not to a Tailscale node.

## Solution

Modify the gateway module to:
1. Add `bind tailscale/storage` directive to all virtual hosts
2. This will create a single Tailscale node named "storage"
3. All 64+ services will be accessible through this one node
4. Expected result: 82 Tailscale nodes → 1 node

## Key Findings from caddy-tailscale Documentation

### How It Works
- **Lazy node creation**: Nodes only register when referenced in bind directives
- **Single node, multiple services**: One node can serve many sites on different ports
- **Example**:
  ```caddyfile
  :80 {
    bind tailscale/myhost
  }
  :8080 {
    bind tailscale/myhost  # Same node, different port
  }
  ```

### OAuth Configuration
- Uses environment variables: `TS_API_CLIENT_ID` and `TS_AUTHKEY`
- Already configured correctly in our setup
- Plugin reads them via `os.Getenv()` (not from Caddyfile)

## Implementation Plan

1. **Update gateway module** (`modules/media/gateway.nix`):
   - Add Tailscale bind directive to virtual host generation
   - Ensure all services bind to `tailscale/storage` instead of `:443`

2. **Test configuration**:
   - Build and verify no errors
   - Check that Caddyfile contains `bind tailscale/storage`

3. **Deploy and verify**:
   - Deploy to storage
   - Verify single "storage" node appears in Tailscale admin
   - Test service accessibility from Tailnet
   - Measure CPU usage (expect ~2-5% vs current ~7%)

4. **Monitor**:
   - Check node is ephemeral
   - Verify automatic re-registration after restart
   - Confirm all 64+ services are accessible

## References

- GitHub: https://github.com/tailscale/caddy-tailscale
- Documentation shows single node can serve multiple services
- Nodes created on-demand when bind directive used

## Current State

- ✅ Caddy running with Tailscale plugin compiled in
- ✅ OAuth environment variables configured (TS_API_CLIENT_ID, TS_AUTHKEY)
- ✅ Tailscale app loaded in Caddy config
- ❌ No Tailscale nodes created (no bind directives)

## Related Tasks

- Closes: task-32 (after completion)
- Related: task-29, task-30, task-31
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Single 'storage' Tailscale node visible in admin console
- [x] #2 Node is ephemeral
- [x] #3 All 64+ services accessible through the node
- [x] #4 CPU usage at 2-5% or similar to current (~7%)
- [x] #5 Node automatically re-registers after Caddy restart
- [x] #6 No errors in Caddy logs
- [x] #7 Services accessible from Tailnet
- [x] #8 Virtual hosts properly bind to tailscale/storage
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. **Update gateway module** (`modules/media/gateway.nix`):
   - Add Tailscale bind directive to virtual host generation
   - Ensure all services bind to `tailscale/storage` instead of `:443`

2. **Test configuration**:
   - Build and verify no errors
   - Check that Caddyfile contains `bind tailscale/storage`

3. **Deploy and verify**:
   - Deploy to storage
   - Verify single "storage" node appears in Tailscale admin
   - Test service accessibility from Tailnet
   - Measure CPU usage (expect ~2-5% vs current ~7%)

4. **Monitor**:
   - Check node is ephemeral
   - Verify automatic re-registration after restart
   - Confirm all 64+ services are accessible

## References

- GitHub: https://github.com/tailscale/caddy-tailscale
- Documentation shows single node can serve multiple services
- Nodes created on-demand when bind directive used

## Current State

- ✅ Caddy running with Tailscale plugin compiled in
- ✅ OAuth environment variables configured (TS_API_CLIENT_ID, TS_AUTHKEY)
- ✅ Tailscale app loaded in Caddy config
- ❌ No Tailscale nodes created (no bind directives)

## Related Tasks

- Closes: task-32 (after completion)
- Related: task-29, task-30, task-31
<!-- SECTION:DESCRIPTION:END -->
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
## Implementation Complete

Successfully configured Caddy virtual hosts to bind to Tailscale node:

### Changes Made
1. **Updated `modules/media/__utils.nix`**: Added `bind tailscale/${config.networking.hostName}` directive to `generateHost` function (modules/media/__utils.nix:75-77)
2. **Updated `modules/media/gateway.nix`**: Added `tags tag:service` to Tailscale configuration (modules/media/gateway.nix:194)

### Results
- ✅ 72 virtual hosts now bind to `tailscale/storage`
- ✅ Single Tailscale node created at `/var/lib/caddy/tailscale/storage`
- ✅ CPU usage: 0.1% (2.27s over 23 minutes) - significantly improved
- ✅ Memory usage: 58.2M (peak: 76.3M)
- ✅ All services accessible via HTTPS
- ✅ Deployment succeeded with no errors
- ✅ Configuration uses OAuth with ephemeral nodes

### Key Discovery
OAuth-based ephemeral Tailscale nodes **require tags** to be specified. Added `tags tag:service` to satisfy this requirement.

### Impact
Reduced from 82 individual Tailscale nodes to 1 Caddy-managed node serving all 64+ services, significantly reducing overhead and CPU usage.
<!-- SECTION:NOTES:END -->
