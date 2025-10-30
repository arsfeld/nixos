---
id: task-103
title: >-
  Replace containerized qbittorrent+VPN with NixOS WireGuard tunnel and native
  qbittorrent service
status: In Progress
assignee: []
created_date: '2025-10-30 21:11'
updated_date: '2025-10-30 22:36'
labels:
  - infrastructure
  - services
  - vpn
  - networking
  - storage
dependencies: []
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Replace the current hotio/qbittorrent container (which has integrated WireGuard VPN) with a native NixOS WireGuard tunnel and qbittorrent systemd service. This solves the VPN return traffic issue by using NixOS's built-in WireGuard support and proper network namespacing/routing.

## Current Issue
The containerized qbittorrent with integrated WireGuard has VPN connectivity problems:
- WireGuard handshake succeeds
- Outbound traffic works (3.51 GB sent)
- **Return traffic completely blocked (only 92 bytes received)**
- DNS resolution fails
- Cannot download any torrents

## Proposed Architecture
1. **Host-level WireGuard tunnel**: Configure WireGuard interface on storage host using NixOS's networking.wg-quick or networking.wireguard
2. **Native qbittorrent service**: Use NixOS qbittorrent-nox service instead of container
3. **Network confinement**: Use network namespaces, routing rules, or nftables to confine qbittorrent traffic to WireGuard tunnel
4. **Local WebUI access**: Expose port 8080 to local network (10.88.0.0/16 Podman network and Tailscale) while routing all torrent traffic through VPN

## Benefits
- Better network stack integration with host
- Easier debugging with standard Linux networking tools
- More reliable VPN connectivity
- Lower overhead (no container network translation)
- Full control over routing rules and firewall
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 WireGuard tunnel configured at NixOS level using AirVPN configuration
- [ ] #2 WireGuard interface establishes connection and passes connectivity tests
- [ ] #3 qbittorrent-nox service configured as native NixOS systemd service
- [ ] #4 qbittorrent torrent traffic confined to WireGuard tunnel (no leaks)
- [ ] #5 Port 8080 (WebUI) accessible from local network and Tailscale
- [ ] #6 Port 8080 NOT exposed through VPN (security)
- [ ] #7 Torrent traffic uses VPN IP address (verify with IP leak test)
- [ ] #8 DNS resolution works correctly for qbittorrent
- [ ] #9 Can successfully download test torrents
- [ ] #10 qui can connect to qbittorrent instance and manage torrents
- [ ] #11 *arr services can connect to qbittorrent
- [ ] #12 Service survives reboots and reconnects automatically
- [ ] #13 Remove old containerized qbittorrent from modules/constellation/media.nix
<!-- AC:END -->
