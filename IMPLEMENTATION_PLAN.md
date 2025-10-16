# Implementation Plan: Replace tsnsrv with Caddy-Tailscale

**Task**: task-29 - Replace tsnsrv with Caddy-Tailscale plugin to reduce CPU overhead
**Goal**: Reduce CPU usage from 60.5% to ~2-5% by replacing 64 separate tsnsrv instances with a single Caddy instance using the Tailscale plugin
**Status**: In Progress

## Overview

Replace the current tsnsrv-based gateway (64 separate Tailscale instances) with a single Caddy instance using the caddy-tailscale plugin from the fork with OAuth2 support (PR #109).

### Current Architecture
- **64 tsnsrv processes**, each creating its own Tailscale node (tsnet.Server)
- Each has its own network monitor polling
- **CPU**: 60.5%
- Access: Both Tailnet (`<service>.bat-boa.ts.net`) and public (via Tailscale Funnel)

### New Architecture
- **1 Caddy instance** with Tailscale plugin (Caddy becomes a Tailscale node)
- **1 Tailscale node** instead of 64
- Caddy handles all reverse proxy routing (unchanged)
- Tailscale Funnel enabled for public access
- Authelia continues as forward auth to Caddy
- **Expected CPU**: ~2-5% (~55% reduction)

## Stages

### Stage 1: Build Custom Caddy Package with Plugin
**Goal**: Create a Caddy package with caddy-tailscale plugin from erikologic/caddy-tailscale fork (PR #109)
**Success Criteria**:
- Custom Caddy package builds successfully
- Plugin from fork (with OAuth2 support) is included
- Package can be referenced in configuration

**Implementation**:
1. Create `packages/caddy-tailscale/default.nix` to build the plugin from fork
2. Update Caddy package to use `pkgs.caddy.withPlugins` with the custom plugin
3. Test build: `nix build .#nixosConfigurations.storage.config.services.caddy.package`

**Tests**:
- [ ] Package builds without errors
- [ ] Plugin is included in Caddy binary
- [ ] Can verify plugin with `caddy list-modules`

**Status**: Not Started

---

### Stage 2: Update Gateway Configuration
**Goal**: Modify gateway.nix to remove tsnsrv and configure Caddy with Tailscale network listener
**Success Criteria**:
- tsnsrv configuration removed (line 147)
- Caddy configured with Tailscale plugin
- Tailscale authentication setup
- Forward auth to Authelia preserved

**Implementation**:
1. Remove `services.tsnsrv.services = tsnsrvConfigs;` from gateway.nix:147
2. Add Tailscale network configuration to Caddy
3. Configure OAuth key for Tailscale node registration
4. Update virtual hosts to use Tailscale listener
5. Ensure forward_auth to Authelia remains intact

**Configuration Changes**:
```nix
# modules/media/gateway.nix
services.caddy = {
  enable = true;
  package = pkgs.caddy-with-tailscale;  # Custom package from Stage 1

  # Tailscale configuration will be added via extraConfig or globalConfig
  # Virtual hosts remain mostly unchanged - still use forward_auth to Authelia
};

# Environment variables for Tailscale OAuth
systemd.services.caddy.environment = {
  TS_AUTHKEY = "...";  # OAuth key from secrets
  # Other Tailscale config as needed
};
```

**Tests**:
- [ ] Configuration evaluates without errors
- [ ] Caddy starts successfully with Tailscale plugin
- [ ] Tailscale node appears in admin console

**Status**: Not Started

---

### Stage 3: Configure Tailscale Funnel and Test Services
**Goal**: Enable Tailscale Funnel for public access and test with 2-3 services
**Success Criteria**:
- Funnel enabled on Caddy's Tailscale node
- 2-3 test services accessible from both Tailnet and public
- Authelia authentication works for both access patterns

**Implementation**:
1. Enable Funnel on the Tailscale node (via Tailscale admin console or config)
2. Test with 2-3 services first (e.g., jellyfin, sonarr, radarr)
3. Verify access patterns:
   - Tailnet: `https://<service>.bat-boa.ts.net`
   - Public: Via Funnel to same URL
4. Verify Authelia forward auth works for both

**Services to Test First**:
- jellyfin (high usage, good test case)
- sonarr (typical service)
- radarr (another typical service)

**Tests**:
- [ ] Services accessible from within Tailnet
- [ ] Services accessible from public via Funnel
- [ ] Authelia authentication prompts appear
- [ ] Login works and redirects to service
- [ ] Service functionality works (can browse Jellyfin, etc.)

**Status**: Not Started

---

### Stage 4: Full Deployment and Monitoring
**Goal**: Deploy to all 64 services and monitor CPU usage
**Success Criteria**:
- All services accessible
- CPU usage reduced to ~2-5%
- No service disruption
- Documentation updated

**Implementation**:
1. Deploy full configuration to storage host
2. Monitor for issues during first hour
3. Verify all services are accessible
4. Monitor CPU usage over 24 hours
5. Update task-29 with results
6. Update documentation if needed

**Monitoring**:
- CPU usage: Should drop from 60.5% to ~2-5%
- Service availability: All 64 services should be accessible
- Error logs: Check Caddy and Tailscale logs for issues
- Performance: Check response times

**Tests**:
- [ ] All 64 services accessible from Tailnet
- [ ] Public services accessible via Funnel (services with `funnel = true`)
- [ ] CPU usage measured at ~2-5%
- [ ] No errors in Caddy logs
- [ ] No errors in Tailscale logs
- [ ] 24-hour stability confirmed

**Status**: Not Started

---

## Technical Notes

### OAuth2 vs Auth Key
PR #109 adds **OAuth key support for node registration** (not user authentication). This allows:
- One OAuth key to register multiple nodes
- Ephemeral node support
- Better automation and key management

Authelia forward auth remains unchanged - it's a standard Caddy feature independent of the Tailscale plugin.

### Key Files to Modify
- `packages/caddy-tailscale/default.nix` (new) - Custom plugin package
- `modules/media/gateway.nix` - Remove tsnsrv, configure Caddy
- `hosts/storage/configuration.nix` - May need to reference custom Caddy package
- `secrets/` - Add Tailscale OAuth key

### Rollback Plan
If issues occur:
1. Revert to previous tsnsrv configuration
2. Redeploy: `just deploy storage`
3. Services should resume normal operation
4. Document issues and reassess approach

## References

- Task: task-29
- Related Task: task-22 (investigation findings)
- PR #109: https://github.com/tailscale/caddy-tailscale/pull/109
- Fork: https://github.com/erikologic/caddy-tailscale
- Upstream: https://github.com/tailscale/caddy-tailscale
