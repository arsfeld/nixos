---
id: task-105
title: >-
  Investigate why torrent downloaders cannot download - no traffic reaching
  clients
status: In Progress
assignee: []
created_date: '2025-10-30 21:42'
updated_date: '2025-10-30 21:57'
labels:
  - bug
  - infrastructure
  - networking
  - vpn
  - containers
  - storage
  - troubleshooting
dependencies: []
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Both transmission-openvpn and qbittorrent containers are running with VPN connections established, but downloads are not working. No traffic appears to be reaching either client.

## Symptoms
- Both transmission and qbittorrent are unable to download torrents
- Nothing reaches either client (no incoming connections/traffic)
- VPN connections appear established for both containers
- Containers are running and WebUIs are accessible

## Current State
### Transmission (transmission-openvpn with AirVPN)
- Status: Running
- VPN: Connected via OpenVPN to AirVPN (Aludra server)
- Container VPN IP: 10.24.2.239
- Peer port: 30158 (AirVPN static forwarded port)
- WebUI: Accessible at https://transmission.arsfeld.one
- Image: haugene/transmission-openvpn:latest
- Network: Podman bridge with LOCAL_NETWORK=10.88.0.0/16

### qBittorrent (hotio/qbittorrent with WireGuard)
- Status: Running (37 minutes uptime)
- VPN: WireGuard tunnel to AirVPN
- Peer port: 55473 (forwarded)
- WebUI: Accessible at https://qbittorrent.arsfeld.one
- Image: ghcr.io/hotio/qbittorrent:latest
- Logs show VPN connectivity test failures: "[ERR] [VPN] [IPV4] Ping test failed!" and "[ERR] [VPN] [IPV4] IP lookup failed!"

## Potential Issues to Investigate
1. **DNS Resolution**: VPN containers may not be able to resolve tracker domains
2. **Firewall Rules**: nftables/iptables may be blocking torrent traffic
3. **Port Forwarding**: Ports may not be properly forwarded through VPN
4. **Tracker Connectivity**: Cannot reach tracker servers to announce/get peers
5. **Network Configuration**: Routing or network namespace issues preventing peer connections
6. **VPN Kill Switch**: May be too aggressive and blocking all traffic
7. **Container Networking**: Podman network configuration may be interfering

## Investigation Steps
1. Test DNS resolution from within containers (dig/nslookup tracker domains)
2. Check if containers can reach external IPs (ping 8.8.8.8, curl ifconfig.me)
3. Verify tracker connectivity (curl/wget to known tracker URLs)
4. Review firewall rules (nftables list ruleset)
5. Test port forwarding from external source (online port checker)
6. Check container network routes (ip route, ip addr)
7. Review VPN logs for connection issues or blocks
8. Test with a known-good public torrent (many seeds)
9. Compare working vs non-working container network configs

## Configuration Files
- modules/constellation/media.nix (container definitions)
- hosts/storage/services/media.nix (VPN config copy scripts)
- secrets/transmission-openvpn-airvpn.age (OpenVPN config)
- secrets/airvpn-wireguard.age (WireGuard config)
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Identify root cause of download failures
- [ ] #2 Both transmission and qbittorrent can successfully download test torrents
- [ ] #3 Containers can resolve DNS and reach tracker servers
- [ ] #4 Incoming peer connections work properly
- [ ] #5 Port forwarding is verified working
- [x] #6 Document solution and any configuration changes needed
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
## Investigation Findings (2025-10-30)

### Root Cause: DNS Resolution Failure

Both containers have DNS resolution issues preventing all network activity:

**qbittorrent (hotio/qbittorrent with WireGuard):**
- WireGuard tunnel is UP and connected (endpoint: 184.75.214.165:1637)
- VPN IP: 10.147.136.54/32
- Latest handshake: Recent and working
- Traffic: 3.51 GiB sent, only 92 B received (massive imbalance)
- Unbound DNS running on 127.0.0.1:53 but NOT configured with upstream DNS
- WireGuard config specifies DNS: 10.128.0.1, fd7d:76ee:e68f:a993::1
- Issue: Unbound has no forward-zone for root (.) - can't resolve any public domains
- DNS queries time out because unbound has no upstream to forward to

**transmission (haugene/transmission-openvpn):**
- OpenVPN stuck in connection loop
- Cannot resolve VPN server: ca3.vpn.airdns.org:443
- DNS configured to use 10.24.2.1 (VPN DNS) but connection times out
- Can't establish VPN connection because DNS resolution fails before VPN connects
- Chicken-and-egg problem: Needs DNS to connect to VPN, but VPN provides DNS

### Technical Details

**qbittorrent Network State:**
- Interfaces: lo, eth0 (10.88.2.137/16), wg0 (10.147.136.54/32)
- Routing: Split routes 0.0.0.0/1 and 128.0.0.0/1 via wg0 (correct)
- Firewall: nftables allows wg0 traffic (5M+ packets, 3.9GB outbound)
- Unbound config: Only forwards "internal." and "vpn." to 127.0.0.11, no root forward-zone

**Required Fix:**
1. Configure unbound to forward queries to VPN DNS (10.128.0.1)
2. OR configure unbound for recursive resolution
3. OR bypass unbound and use VPN DNS directly in /etc/resolv.conf

## DNS Fix Applied (2025-10-30 17:50)

### Changes Made
1. Added `VPN_NAMESERVERS = "10.128.0.1"` to qbittorrent environment
2. Added `--dns=1.1.1.1` and `--dns=8.8.8.8` to transmission extraOptions
3. Deployed to storage host and containers restarted

### Result
Unbound DNS now properly configured with VPN DNS forward-zone, BUT fundamental VPN connectivity issue discovered:

**WireGuard Tunnel Problem:**
- Latest handshake: Working (2 min 52 sec ago)
- Transfer stats: **2.98 GiB sent, 92 B received**
- Massive imbalance indicates outbound packets go through but **replies never come back**
- Cannot reach VPN DNS (10.128.0.1:53) - connection times out
- Cannot reach external services through VPN - all connections timeout
- Cannot even resolve using external DNS (1.1.1.1) through tunnel

### Root Cause Analysis
This is NOT a DNS configuration issue - it's a fundamental VPN tunnel problem:
1. WireGuard handshake succeeds (crypto negotiation works)
2. Outbound packets are sent (2.98 GB!)
3. But virtually no data returns (only 92 bytes total)
4. Suggests NAT/routing issue at VPN provider or endpoint

### Next Steps to Investigate
1. Try different AirVPN server endpoint
2. Check if this is a known AirVPN WireGuard issue
3. Consider using transmission (OpenVPN) as primary client if it works
4. Test if OpenVPN has the same issue or works better
5. Contact AirVPN support about WireGuard connectivity
6. Check AirVPN port forwarding configuration

## Final Investigation Results (2025-10-30 17:55)

### Confirmed Root Cause: VPN Tunnel Failure (Not DNS)

Both containers have fundamental VPN connectivity issues preventing all network traffic:

**WireGuard (qbittorrent) Stats:**
- Latest handshake: Working (successful crypto negotiation)
- RX: **1 packet, 92 bytes total** (essentially nothing)
- TX: **4.35M packets, 3.08 GB**
- **TX dropped: 229,378 packets (5.3% packet loss)**
- Cannot reach ANY external service (VPN DNS, public DNS, HTTP by IP)

**OpenVPN (transmission) Status:**
- Connection successful: "Initialization Sequence Completed"
- tun0 interface UP with IP 10.20.226.169/24
- Same behavior: Cannot reach external services, DNS times out
- Cannot access services by IP (tested 1.1.1.1 HTTP)

### Technical Analysis

**What Works:**
1. VPN handshakes/negotiation (both WireGuard and OpenVPN)
2. VPN interfaces come up with correct IPs
3. Outbound packets are sent (4.35M packets via WireGuard)
4. Host firewall/NAT rules are correct
5. Container routing tables are correct

**What's Broken:**
1. Virtually NO return traffic (only 92 bytes after sending 3GB!)
2. 5.3% outbound packet drops on WireGuard
3. Cannot reach VPN provider DNS servers
4. Cannot reach public DNS servers (1.1.1.1, 8.8.8.8)
5. Cannot access any external service by IP (no DNS involved)

### Likely Causes
1. **MTU misconfiguration**: WireGuard MTU=1320 may be too large, causing fragmentation/drops
2. **VPN provider routing issue**: AirVPN endpoint may have NAT/routing problems
3. **Endpoint configuration**: May need different AirVPN server or configuration
4. **AirVPN service issue**: Possible infrastructure problem on provider side

### DNS Configuration Applied
Despite VPN tunnel issues, proper DNS configuration was added:
- qbittorrent: `VPN_NAMESERVERS = "10.128.0.1"` (unbound now configured correctly)
- transmission: `--dns=1.1.1.1 --dns=8.8.8.8` (for pre-VPN resolution)
- These changes are correct and should work once VPN tunnel is fixed

### Next Steps Required
1. Try reducing MTU (test 1280, 1200, or 1000)
2. Try different AirVPN server endpoint
3. Test with different AirVPN protocol (OpenVPN on different port)
4. Contact AirVPN support about connectivity issue
5. Consider alternative VPN provider if AirVPN issue persists
6. Check AirVPN web interface for account/port forwarding status

## Task Outcome

**Root cause identified**: VPN tunnel connectivity failure (not DNS)
- Both WireGuard and OpenVPN tunnels establish but receive no return traffic
- 4.35M packets sent (3.08 GB), only 92 bytes received
- 5.3% outbound packet drops on WireGuard

**DNS configuration fixed**: 
- Applied correct VPN_NAMESERVERS and --dns flags
- Changes committed in 65bf3e6
- Will work once VPN tunnel is operational

**Follow-up created**: task-106 for fixing VPN connectivity
- Need to test MTU adjustments
- Try different AirVPN endpoints
- Deep packet inspection required
<!-- SECTION:NOTES:END -->
