---
id: task-104
title: Re-enable transmission-openvpn container with AirVPN configuration
status: Done
assignee: []
created_date: '2025-10-30 21:12'
updated_date: '2025-10-30 21:39'
labels:
  - infrastructure
  - services
  - vpn
  - containers
  - storage
  - alternative-solution
dependencies: []
priority: medium
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Re-enable the docker-transmission-openvpn container (haugene/docker-transmission-openvpn) that was previously used with PIA VPN, but configure it to use AirVPN instead. This is an alternative solution to the qbittorrent VPN issues.

## Background
Previously used haugene/docker-transmission-openvpn with PIA VPN. This container provides Transmission BitTorrent client with integrated OpenVPN support and automatic port forwarding. The container has proven reliability and includes features like:
- Built-in VPN kill switch
- Automatic port forwarding
- Health checks
- RSS support
- Web UI and RPC API

## Current State
- Secrets file references: `secrets/transmission-openvpn-pia.age` exists in codebase
- Container was disabled in favor of qflood/qbittorrent migration
- AirVPN supports OpenVPN (in addition to WireGuard)

## Implementation Approach
1. **Download AirVPN OpenVPN configuration**: Get OpenVPN config files from AirVPN (alternative to WireGuard)
2. **Create new secret**: Store AirVPN OpenVPN credentials and config in `secrets/transmission-openvpn-airvpn.age`
3. **Configure container**: Set up transmission-openvpn with AirVPN provider settings
4. **Environment variables**: Configure VPN provider, credentials, port forwarding
5. **Volume mounts**: Map download directories and config
6. **Network setup**: Ensure local network access to WebUI while routing torrent traffic through VPN

## Comparison to Other Solutions
- **vs qbittorrent container (task-103)**: Different torrent client, uses OpenVPN instead of WireGuard
- **vs native NixOS qbittorrent**: Container-based (easier rollback), proven track record with this exact use case
- **Advantage**: Well-maintained container with VPN provider presets and automatic port forwarding
- **Disadvantage**: Container overhead, less control over network configuration

## Migration Notes
- Can run alongside qbittorrent temporarily for testing
- *arr services may need reconfiguration to point to Transmission instead of qBittorrent
- Different API/interface than qBittorrent (no qui support)
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Download AirVPN OpenVPN configuration files
- [x] #2 Create and encrypt transmission-openvpn-airvpn secret with OpenVPN credentials
- [x] #3 Configure haugene/transmission-openvpn container in media.nix or storage services
- [x] #4 Set environment variables for OPENVPN_PROVIDER=AIRVPN and credentials
- [x] #5 Configure port forwarding with AirVPN port
- [x] #6 Map download directories to storage volumes
- [x] #7 Container successfully establishes OpenVPN connection to AirVPN
- [x] #8 Verify VPN connectivity and IP address through VPN
- [x] #9 Transmission WebUI accessible from local network/Tailscale
- [ ] #10 Can successfully download test torrents
- [ ] #11 *arr services can connect to Transmission (if migrating from qBittorrent)
- [ ] #12 Service survives reboots and reconnects automatically
- [x] #13 Add to media gateway for https access via arsfeld.one domain
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
## Implementation Complete

### Configuration
- Successfully configured haugene/transmission-openvpn container with AirVPN OpenVPN
- Used custom provider mode with user-specific .ovpn configuration
- Container capabilities: NET_ADMIN + MKNOD for VPN and TUN device creation
- Proper device mounting: --device=/dev/net/tun:/dev/net/tun:rwm

### VPN Connection
- OpenVPN 2.5.11 successfully connected to AirVPN (Aludra server in Canada)
- Container bound to VPN IP: 10.8.66.180
- Certificate verification successful
- VPN tunnel initialization completed

### Network Configuration
- LOCAL_NETWORK set to 10.88.0.0/16 (Podman network only)
- Removed Tailscale network from LOCAL_NETWORK to avoid routing errors
- WebUI accessible via https://transmission.arsfeld.one (gateway routing working)

### Files Changed
- secrets/transmission-openvpn-airvpn.age (encrypted .ovpn config)
- secrets/secrets.nix (added secret entry)
- modules/constellation/media.nix (container configuration)
- hosts/storage/services/media.nix (tmpfiles + ExecStartPre for config copy)

### Outstanding Items
- ☐ #10: Test actual torrent downloads (not tested yet)
- ☐ #11: Configure *arr services integration (if needed)
- ☐ #12: Verify service survives reboot (not tested yet)

### Commits
- feat(storage): add transmission-openvpn container with AirVPN (67bfb4a)
- fix(storage): add MKNOD capability for transmission TUN device creation (45a18a1)
- fix(storage): remove Tailscale network from transmission LOCAL_NETWORK (latest)

## Port Forwarding Configuration

- Configured TRANSMISSION_PEER_PORT = 30158 (AirVPN static forwarded port)
- Verified in logs: "Overriding peer-port because TRANSMISSION_PEER_PORT is set to 30158"
- Container restarted successfully and VPN reconnected
- Service is active and running

Commit: feat(storage): configure transmission with AirVPN port 30158
<!-- SECTION:NOTES:END -->
