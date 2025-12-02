---
id: task-153.8
title: Investigate why brazil-exit node is not working from other Tailscale clients
status: Done
assignee: []
created_date: '2025-11-30 20:57'
updated_date: '2025-11-30 21:55'
labels:
  - bug
  - tailscale
  - vpn
  - networking
dependencies: []
parent_task_id: task-153
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
## Problem

The brazil-exit node appears to be running and offering exit node capability in `tailscale status`, but clients cannot successfully use it as an exit node.

## Current State

- Gluetun container: healthy, connected to AirVPN Brazil (146.70.248.10)
- Tailscale container: running, connected, advertising as exit node
- Node visible in tailnet as `brazil-exit.bat-boa.ts.net`

## Investigation Steps

1. **Test from another client**
   ```bash
   tailscale set --exit-node=brazil-exit
   curl ifconfig.me
   ```

2. **Check exit node routing**
   - Verify IP forwarding is enabled in gluetun container
   - Check iptables rules in both containers
   - Verify Tailscale is properly forwarding traffic

3. **Check logs during connection attempt**
   - `sudo podman logs tailscale-exit-brazil`
   - Look for connection/routing errors

4. **Verify network namespace configuration**
   - Tailscale container uses `--network=container:gluetun-exit-brazil`
   - Traffic should flow: client → tailscale container → gluetun → AirVPN

5. **Check IPv6 forwarding warning**
   - Logs show "IPv6 forwarding is disabled. Subnet routes and exit nodes may not work correctly"
   - May need to enable IPv4/IPv6 forwarding in gluetun container

## Potential Issues

- Missing sysctl settings for IP forwarding
- Firewall rules blocking forwarded traffic
- Network namespace routing issues
- Gluetun firewall blocking Tailscale traffic
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Clients can successfully set brazil-exit as exit node
- [x] #2 Traffic from clients routes through Brazilian IP
- [x] #3 curl ifconfig.me shows Brazilian IP when using exit node
- [x] #4 No routing errors in container logs
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
## Root Cause

Three issues were identified:

1. **Conflicting routing rules**: `FIREWALL_OUTBOUND_SUBNETS` included `100.64.0.0/10` which created gluetun routing rules (table 199, priority 99) that conflicted with Tailscale's routing (table 52, priority 5270). Return traffic was routed via eth0 instead of tailscale0.

2. **Route priority**: Gluetun's VPN rule (priority 101) had higher priority than Tailscale's rule (priority 5270), causing traffic TO Tailscale clients to go via tun0 instead of tailscale0.

3. **IPv6 forwarding disabled**: Tailscale warned this could affect exit node functionality.

## Fixes Applied

1. Removed `100.64.0.0/10` from `FIREWALL_OUTBOUND_SUBNETS` in `vpn-exit-nodes.nix`
2. Added ExecStartPost to inject `ip rule add to 100.64.0.0/10 lookup 52 priority 100`
3. Added sysctls for IPv6 forwarding: `net.ipv6.conf.all.forwarding=1`

## Verification

Tested from iPhone - exit node now correctly routes traffic through Brazilian IP (146.70.248.x).
<!-- SECTION:NOTES:END -->
