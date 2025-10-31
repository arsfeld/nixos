---
id: task-116
title: Investigate why transmission.arsfeld.one is not accessible
status: Done
assignee: []
created_date: '2025-10-31 18:13'
updated_date: '2025-10-31 18:19'
labels:
  - bug
  - transmission
  - networking
  - gateway
dependencies:
  - task-108
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
The transmission service at https://transmission.arsfeld.one/ is not working. Need to investigate the root cause, which could be:
- Gateway/Caddy reverse proxy configuration issue
- Service not running or misconfigured
- DNS resolution problem
- Related to the ongoing native NixOS service migration (task-108)
- Port binding or network connectivity issue
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Identify the specific cause of transmission.arsfeld.one not being accessible
- [x] #2 transmission.arsfeld.one returns a working response (200 OK or proper service UI)
- [x] #3 Service is accessible both internally (within tailnet) and externally (if configured)
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
## Root Cause
The transmission service was running correctly in the VPN namespace (192.168.15.1:9091), but the gateway configuration wasn't set up to proxy to the VPN namespace IP.

## Solution
Added gateway host override in transmission-vpn.nix:
```nix
media.gateway.services.transmission.host = lib.mkForce "192.168.15.1";
```

This tells the Caddy gateway on storage to proxy requests to the VPN namespace IP (192.168.15.1) instead of localhost.

## Architecture
- External: transmission.arsfeld.one → cloud (gateway) → storage:9091 → VPN namespace (192.168.15.1:9091)
- Internal (tailnet): transmission.arsfeld.one → storage Caddy → VPN namespace (192.168.15.1:9091)
- Port mapping configured in qbittorrent-vpn.nix forwards host port 9091 to namespace

## Testing
Verified that https://transmission.arsfeld.one/ loads the Flood UI correctly.
<!-- SECTION:NOTES:END -->
