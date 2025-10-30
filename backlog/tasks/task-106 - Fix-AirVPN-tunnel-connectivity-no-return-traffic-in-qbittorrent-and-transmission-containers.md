---
id: task-106
title: >-
  Fix AirVPN tunnel connectivity - no return traffic in qbittorrent and
  transmission containers
status: To Do
assignee: []
created_date: '2025-10-30 21:56'
labels:
  - bug
  - networking
  - vpn
  - containers
  - storage
  - airvpn
dependencies:
  - task-105
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
## Problem

Both torrent client containers have VPN tunnels that establish successfully but receive virtually no return traffic:

**Symptoms:**
- WireGuard (qbittorrent): 4.35M packets sent (3.08 GB), only 1 packet received (92 bytes)
- OpenVPN (transmission): Connection established but same behavior
- 5.3% outbound packet loss on WireGuard (229K dropped packets)
- Cannot reach any external service (VPN DNS, public DNS, HTTP by IP)
- VPN handshakes work correctly (crypto negotiation successful)

**What Works:**
- VPN handshakes/negotiation complete successfully
- VPN interfaces come up with correct IPs
- Outbound packets are transmitted
- Host firewall/NAT rules are correct
- Container routing is correct

**What's Broken:**
- Virtually NO return traffic through VPN tunnels
- Cannot access any external service through VPN
- High outbound packet drop rate on WireGuard

## Investigation Needed

1. **MTU Testing**: Current WireGuard MTU=1320 may be too large
   - Test with MTU 1280, 1200, 1000
   - Check if this resolves packet drops and connectivity

2. **AirVPN Endpoint**: Current endpoint may have issues
   - Try different AirVPN server (not ca3)
   - Check AirVPN status page for known issues
   - Verify account status and port forwarding config

3. **Protocol Testing**: Compare WireGuard vs OpenVPN behavior
   - Both currently fail the same way
   - Try OpenVPN on different port
   - Test if issue is protocol-specific or provider-wide

4. **Network Debugging**: Deep packet inspection
   - Use tcpdump to capture VPN traffic
   - Check if replies are received at network level but dropped
   - Verify NAT traversal is working

## References

- Investigation documented in task-105
- DNS configuration already fixed (will work once VPN is operational)
- modules/constellation/media.nix:208-227 (qbittorrent)
- modules/constellation/media.nix:257-293 (transmission)
- secrets/airvpn-wireguard.age (WireGuard config)
- secrets/transmission-openvpn-airvpn.age (OpenVPN config)
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 VPN tunnels receive return traffic (RX/TX ratio reasonable)
- [ ] #2 Can resolve DNS through VPN tunnel
- [ ] #3 Can access external services (curl ifconfig.me works)
- [ ] #4 Packet drop rate on WireGuard < 1%
- [ ] #5 Both qbittorrent and transmission can download torrents
- [ ] #6 Document solution and any MTU/configuration changes needed
<!-- AC:END -->
