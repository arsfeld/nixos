---
id: task-29
title: Replace tsnsrv with Caddy-Tailscale plugin to reduce CPU overhead
status: To Do
assignee: []
created_date: '2025-10-16 03:37'
updated_date: '2025-10-16 03:56'
labels:
  - implementation
  - performance
  - tailscale
  - caddy
  - infrastructure
dependencies:
  - task-22
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Replace the current tsnsrv-based gateway (64 separate Tailscale instances) with a single Caddy instance using the caddy-tailscale plugin.

## Context

Task-22 investigation revealed that tsnsrv creates 64 separate Tailscale nodes (one per service), consuming 60.5% CPU. The solution is to use Caddy with the Tailscale plugin, making Caddy itself a single Tailscale node that handles all services.

## Important: OAuth2 Support Required

**We need to use the fork from PR #109** which adds OAuth2 support:
https://github.com/tailscale/caddy-tailscale/pull/109

The upstream caddy-tailscale doesn't yet support OAuth2, which we need for Authelia integration. This PR adds the necessary OAuth2 authentication support.

## Solution Architecture

**Current (tsnsrv)**:
- 64 separate tsnsrv processes
- Each creates its own Tailscale node (tsnet.Server)
- Each has its own network monitor polling
- CPU: 60.5%

**New (caddy-tailscale)**:
- 1 Caddy instance with Tailscale plugin (from fork)
- Caddy joins Tailnet as a single node
- Caddy handles all reverse proxy routing
- Tailscale Funnel enabled for public access
- OAuth2 support for Authelia integration
- Expected CPU: ~2-5% (~55% reduction)

## Access Patterns

- **Tailnet users**: Connect directly to Caddy via Tailscale (fast, `<service>.bat-boa.ts.net`)
- **Public users**: Connect via Tailscale Funnel to same Caddy
- **Custom domain** (arsfeld.one): Handled by existing cloud host proxy
- **HTTPS**: Tailscale certs for .ts.net + ACME for custom domains
- **Auth**: Authelia continues as forward auth to Caddy (via OAuth2)

## Implementation Steps

1. **Package caddy-tailscale plugin from fork** (PR #109 with OAuth2 support)
   - Check if available in nixpkgs, otherwise build from fork
   - Ensure OAuth2 authentication is enabled
2. Update `modules/media/gateway.nix`:
   - Remove tsnsrv configuration (line 147)
   - Configure Caddy with Tailscale plugin
   - Add Tailscale authentication/network config
   - Configure OAuth2 integration with Authelia
3. Configure Tailscale Funnel for public access
4. Test with 2-3 services first
5. Verify both Tailnet and public access work
6. Verify Authelia OAuth2 authentication works
7. Deploy to all services
8. Monitor CPU usage to confirm reduction

## Key Changes

- `modules/media/gateway.nix`: Remove tsnsrv, add caddy-tailscale (from fork)
- Caddy config: Add Tailscale network listener with OAuth2
- Keep all existing: Authelia, service routing, CORS, error pages

## Benefits

- ✅ ~55% CPU reduction (60.5% → 2-5%)
- ✅ Fast local Tailnet access (unchanged)
- ✅ Public access via Funnel (unchanged)
- ✅ OAuth2 support for Authelia
- ✅ Simple architecture (remove tsnsrv)
- ✅ No vendor lock-in
- ✅ Unified configuration
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Caddy running with caddy-tailscale plugin
- [ ] #2 Single Tailscale node (Caddy) instead of 64 (tsnsrv)
- [ ] #3 All services accessible via Tailnet (<service>.bat-boa.ts.net)
- [ ] #4 Public access working via Tailscale Funnel
- [ ] #5 Authelia authentication functional
- [ ] #6 CPU usage reduced to ~2-5% (from 60.5%)
- [ ] #7 No service disruption or downtime
- [ ] #8 Documentation updated
<!-- AC:END -->
