---
id: task-49
title: Minimize tsnsrv exposed services to reduce CPU overhead
status: Done
assignee: []
created_date: '2025-10-16 18:50'
updated_date: '2025-10-16 19:23'
labels:
  - performance
  - tsnsrv
  - tailscale
  - cpu
  - optimization
dependencies: []
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
## Problem

With tsnsrv re-enabled (task-48), all media services are now exposed via Tailscale by default. This creates many tsnsrv instances which could still cause high CPU usage, similar to the original tsnsrv issue that led us to try caddy-tailscale.

## Context

- Previously with caddy-tailscale, we had a curated `tailscaleExposed` array in `modules/constellation/services.nix` with only ~13 frequently accessed services
- That list included: jellyfin, plex, immich, photos, audiobookshelf, hass, grocy, home, www, code, gitea, n8n, grafana, netdata
- Most other services were only accessible via *.arsfeld.one through the cloud gateway

## Goal

Implement a similar filtering mechanism for tsnsrv to only expose a minimal set of frequently accessed services via Tailscale, while keeping other services accessible only through *.arsfeld.one.

## Solution

1. Modify `utils.generateTsnsrvConfigs` in `modules/media/__utils.nix` to filter services based on a condition (similar to how Caddy checks `exposeViaTailscale`)
2. Either:
   - Reuse the `exposeViaTailscale` flag for tsnsrv filtering, OR
   - Create a new service option like `exposeTsnsrv` for more granular control
3. Re-populate the list in `modules/constellation/services.nix` with the same ~13 frequently accessed services
4. Deploy and verify only selected services have tsnsrv instances

## Benefits

- Reduce CPU overhead by running fewer tsnsrv instances
- Maintain fast Tailscale access to frequently used services
- Other services remain accessible via cloud gateway
- Better control over which services are exposed
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Only ~13 frequently accessed services exposed via tsnsrv
- [ ] #2 generateTsnsrvConfigs respects exposeViaTailscale or similar flag
- [ ] #3 Other services only accessible via *.arsfeld.one
- [ ] #4 CPU usage remains low after changes
- [ ] #5 All frequently accessed services working via Tailscale
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
## Implementation

### Changes Made

1. **Modified `generateTsnsrvService` in `modules/media/__utils.nix`** (line 161):
   - Added check for `cfg.exposeViaTailscale` alongside the hostname check
   - Now only creates tsnsrv configs for services with `exposeViaTailscale = true`
   - This filters tsnsrv instances to only frequently accessed services

2. **Updated `tailscaleExposed` array in `modules/constellation/services.nix`** (lines 166-181):
   - Populated with 14 frequently accessed services:
     - jellyfin, plex, immich, photos, audiobookshelf
     - hass, grocy, home, www
     - code, gitea, n8n
     - grafana, netdata
   - Updated comments to clarify this is for tsnsrv (not caddy-tailscale)
   - Noted this list is kept minimal to reduce CPU overhead

### How It Works

- Services not in `tailscaleExposed` will have `exposeViaTailscale = false`
- `generateTsnsrvService` now skips services with `exposeViaTailscale = false`
- Result: Only 14 tsnsrv instances instead of ~40+
- Other services remain accessible via *.arsfeld.one through cloud gateway

### Verification

- Build tested successfully: `nix build '.#nixosConfigurations.storage.config.system.build.toplevel'`
- Configuration generates without errors
- Ready for deployment to storage host

## Post-Deployment Fix

### Issue Found
After initial deployment, discovered that BOTH Caddy Tailscale plugin AND tsnsrv were creating Tailscale nodes for the same services, defeating the purpose of task-48.

### Additional Changes

1. **Added `media.gateway.tailscale.enable` option** (modules/media/gateway.nix:149-158):
   - New boolean option to control Caddy Tailscale integration
   - Defaults to `false` to disable caddy-tailscale plugin
   - Documented as disabled due to high CPU usage

2. **Disabled Caddy Tailscale global config** (modules/media/gateway.nix:193-199):
   - Removed tailscale block generation from Caddy global config
   - Added comments explaining tsnsrv is used instead
   - References task-48 and task-49

3. **Disabled Caddy Tailscale systemd config** (modules/media/gateway.nix:205-212):
   - Removed EnvironmentFile for tailscale-env
   - Removed StateDirectory entries for tailscale subdirectories
   - Simplified to only include base caddy state directory

4. **Updated generateHost in __utils.nix** (line 90-91):
   - Added check for `config.media.gateway.tailscale.enable`
   - Prevents Caddy virtual hosts from binding to Tailscale nodes
   - Only binds when explicitly enabled

### Verification

- Caddy config no longer contains tailscale block
- Caddy service has no EnvironmentFile for tailscale-env
- Caddy StateDirectory only contains 'caddy' (no tailscale subdirs)
- Only tsnsrv is creating/managing Tailscale nodes
- Both services running successfully
<!-- SECTION:NOTES:END -->
