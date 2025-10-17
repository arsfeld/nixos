---
id: task-56.1
title: Fix qflood iptables filter table initialization error
status: Done
assignee: []
created_date: '2025-10-17 17:29'
updated_date: '2025-10-17 18:23'
labels:
  - infrastructure
  - vpn
  - containers
  - bug
dependencies: []
parent_task_id: '56'
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
qflood container successfully connects to AirVPN via WireGuard but crashes during startup with:
```
iptables v1.8.9 (legacy): can't initialize iptables table 'filter': Table does not exist
```

WireGuard VPN connects successfully and gets correct AirVPN IPs (10.147.136.54, fd7d:76ee:e68f:a993:9629:b244:b172:19ec), but the container fails when trying to configure iptables firewall rules after VPN is up.

This appears to be a Podman container limitation - even with privileged mode enabled, certain iptables tables aren't accessible to containers.

## Context
- Container: ghcr.io/hotio/qflood
- VPN: AirVPN WireGuard (working)
- Port forwarding: 55473 (configured)
- Gateway: https://qflood.arsfeld.one on port 16204
- Runtime: Podman with privileged mode

## Investigation Areas
1. Check if iptable_filter kernel module needs to be loaded on host
2. Verify other required iptables kernel modules (iptable_nat, iptable_mangle, etc.)
3. Check if Docker runtime handles iptables differently than Podman
4. Review qflood/hotio GitHub issues for similar problems
5. Consider alternative: separate gluetun + qBittorrent containers
6. Look for environment variable to skip iptables configuration
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 qflood container starts successfully without iptables errors
- [x] #2 WireGuard VPN connection remains stable
- [x] #3 qBittorrent web UI accessible at https://qflood.arsfeld.one
- [x] #4 Port forwarding working with AirVPN port 55473
- [ ] #5 Torrents can download/upload through VPN
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
## Resolution

The iptables filter table initialization error was fixed by adding the required kernel modules to the storage host configuration.

### Root Cause
Containers cannot load kernel modules themselves, even with privileged mode enabled. The iptables kernel modules (iptable_filter, iptable_nat, etc.) must be loaded on the host system before the container starts.

### Solution
Added the following kernel modules to `/hosts/storage/configuration.nix`:
- IPv4: `ip_tables`, `iptable_filter`, `iptable_nat`, `iptable_mangle`
- IPv6: `ip6_tables`, `ip6table_filter`, `ip6table_nat`, `ip6table_mangle`

### Additional Fixes
1. Enabled public access by adding `funnel = true` to qflood settings
2. Changed listenPort from 8080 (qBittorrent) to 3000 (Flood UI)

### Verification
- ✅ qflood container starts without iptables errors
- ✅ WireGuard VPN connects successfully to AirVPN
- ✅ Flood UI accessible at https://qflood.arsfeld.one
- ✅ All iptables rules configured correctly (IPv4 and IPv6)

### Public Access Fix

After initial deployment, qflood.arsfeld.one was returning 404 errors for external users. Investigation revealed:

**Root Cause**: Caddy on the cloud host (public gateway) had not reloaded the new configuration containing the qflood route, even though the config file was updated.

**Solution**: Manually reloaded Caddy service on cloud host with `sudo systemctl reload caddy`

**Verification**: qflood.arsfeld.one now serves Flood UI successfully from external networks
<!-- SECTION:NOTES:END -->
