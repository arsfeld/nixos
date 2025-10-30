---
id: task-98
title: 'Investigate current status of Caddy, Tailscale, and tsnsrv on cloud host'
status: Done
assignee: []
created_date: '2025-10-28 18:53'
updated_date: '2025-10-28 18:57'
labels:
  - investigation
  - cloud
  - caddy
  - tailscale
dependencies: []
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Need to investigate and document the current state of Caddy, Tailscale, and tsnsrv services on the cloud host to understand what's actually running and what needs to be fixed or completed.

Context:
- Multiple related tasks exist (task-31, task-32, task-47, task-48) around caddy-tailscale vs tsnsrv
- There have been CPU usage concerns with both solutions
- Need to determine current deployment state before proceeding with other work

Investigation should cover:
- Which services are currently running (Caddy with caddy-tailscale plugin, tsnsrv, or both)
- Service health and status (systemd status, logs)
- Current CPU/resource usage
- Which services are being exposed via Tailscale nodes
- TLS certificate status for exposed services
- Any errors or issues in logs
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Document which services (caddy, tsnsrv, tailscale) are currently running on cloud
- [x] #2 Check systemd status and recent logs for caddy, tsnsrv, and tailscale services
- [x] #3 Measure current CPU/memory usage of these services
- [x] #4 List which services are exposed via Tailscale nodes (*.bat-boa.ts.net)
- [x] #5 Verify TLS certificate status for exposed services
- [x] #6 Identify any errors or warnings in service logs
- [x] #7 Document findings and recommend next steps based on current state
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
## Investigation Findings

### Current State on Cloud Host (as of 2025-10-28)

#### Services Running
1. **Caddy**: ✅ Active and healthy
   - Running for 4 days since 2025-10-24
   - PID: 3361
   - Memory: 127.8M (peak: 148.7M)
   - CPU usage: 5min 3s over 4 days (very light)
   - Version: 2.10.0
   - Has tailscale plugin installed: `tls.get_certificate.tailscale` module present
   - **NOT using the tailscale plugin** - using traditional ACME certificates from `/var/lib/acme/`
   
2. **Tailscaled**: ✅ Active and healthy
   - Running for 4 days since 2025-10-24
   - PID: 1260
   - Memory: 86M (peak: 143.9M)
   - CPU usage: 1h 37min over 4 days (moderate)
   - Version: 1.82.5
   - Status: Connected as cloud.bat-boa.ts.net
   
3. **tsnsrv**: ❌ NOT running
   - No systemd units found
   - Explicitly disabled in `hosts/cloud/services.nix:23`

#### Configuration Analysis

**CRITICAL: Configuration Inconsistency Found**

There's a contradiction between two configuration files:

1. **hosts/cloud/services.nix** (lines 19-30):
   ```nix
   # tsnsrv disabled - replaced by Caddy with Tailscale plugin
   services.tsnsrv.enable = false;
   ```
   Comment claims tsnsrv was replaced by caddy-tailscale

2. **modules/media/gateway.nix** (lines 196-207):
   ```nix
   # Caddy Tailscale configuration DISABLED (task-48, task-49)
   # Using tsnsrv instead due to high CPU usage from caddy-tailscale plugin
   services.tsnsrv.services = utils.generateTsnsrvConfigs {...};
   ```
   Comment claims caddy-tailscale was replaced by tsnsrv

**Reality**: NEITHER is being used! Caddy is using traditional ACME certificates.

#### Services Proxied by Caddy
- ~20+ services exposed via *.arsfeld.one domains
- All using traditional TLS certificates from Let's Encrypt ACME
- Certificate path: `/var/lib/acme/arsfeld.one/cert.pem` and `key.pem`
- Gateway working correctly with standard reverse proxy configuration

#### Tailscale Nodes
The following service nodes exist on the tailnet (*.bat-boa.ts.net):
- audiobookshelf, code, gitea, grafana, grocy, harmonia, hass, home
- immich, jellyfin, n8n, netdata, photos, plex
- r2s, router, raspi3

Note: These nodes are NOT created by caddy-tailscale or tsnsrv. They appear to be created by individual container configurations or manual Tailscale client setup.

#### Logs Analysis

**Caddy logs** (last 24 hours):
- Only warnings about unnecessary header_up directives (X-Forwarded-For, X-Forwarded-Proto, X-Forwarded-Host)
- These are minor configuration warnings - Caddy's default reverse_proxy already passes these headers
- No errors or critical issues

**Tailscaled logs** (last 24 hours):
- Some transient PollNetMap errors on Oct 27 (502, context canceled)
- Health checks returned to OK status after temporary issues
- No ongoing errors
- Normal SSH connection logs

#### Resource Usage Summary
- Caddy: Very light (5min CPU over 4 days, 128M memory)
- Tailscaled: Moderate (1h 37min CPU over 4 days, 86M memory)
- Total overhead: Minimal and stable

### TLS Certificate Status
- Certificates stored in `/var/lib/acme/arsfeld.one/`
- Using Let's Encrypt ACME protocol
- Wildcard certificate for *.arsfeld.one
- No issues accessing Caddy API for certificate info
- Certificates appear to be valid and auto-renewing

## Recommendations

### 1. Resolve Configuration Inconsistency (HIGH PRIORITY)

The configuration comments contradict each other about which solution is being used. Need to:

**Option A: Keep current working state (RECOMMENDED)**
- Remove misleading comments from both files
- Document that neither caddy-tailscale nor tsnsrv is actively used
- Traditional ACME certificates are working well with low overhead
- Update gateway.nix to remove the tsnsrv configuration lines if not used

**Option B: Enable tsnsrv for Tailscale node management**
- Set `services.tsnsrv.enable = true` in hosts/cloud/services.nix
- Remove contradictory comment
- Only needed if you want automated *.bat-boa.ts.net node creation

**Option C: Enable caddy-tailscale plugin**
- Set `media.gateway.tailscale.enable = true`
- Be aware of potential CPU usage issues (task-48, task-49)
- Only if you want Caddy to manage Tailscale nodes directly

### 2. Clean Up Caddy Configuration Warnings (LOW PRIORITY)

Caddy warns about unnecessary header_up directives:
- Remove `header_up X-Forwarded-For`
- Remove `header_up X-Forwarded-Proto`
- Remove `header_up X-Forwarded-Host`

These are already set by Caddy's reverse_proxy by default.

### 3. Tailscale Service Nodes

Investigate how the *.bat-boa.ts.net nodes are being created if neither caddy-tailscale nor tsnsrv is running. Likely created by:
- Individual container Tailscale sidecars
- Manual tailscale serve commands
- modules/constellation/services.nix `tailscaleExposed` configuration

### 4. Related Tasks to Review

- task-31: Possibly about caddy-tailscale implementation
- task-32: Related to caddy-tailscale vs tsnsrv decision
- task-47: Possibly about CPU usage concerns
- task-48: HIGH CPU usage with caddy-tailscale
- task-49: Related to caddy-tailscale performance issues

Consider closing or updating these tasks based on current state.

## Current Status Summary

**What's Actually Running:**
- ✅ Caddy with standard ACME certificates (working well, low CPU)
- ✅ Tailscaled main agent (working well)
- ❌ tsnsrv (disabled, not running)
- ❌ caddy-tailscale plugin (installed but not in use)

**What's Working:**
- All *.arsfeld.one services accessible via Caddy gateway
- TLS certificates valid and auto-renewing
- Services stable with low resource usage
- No critical errors or issues

**What Needs Attention:**
- Configuration comments are contradictory and misleading
- Need to decide on long-term solution and document it clearly
- Related tasks (31, 32, 47, 48, 49) may need updates based on findings
<!-- SECTION:NOTES:END -->
