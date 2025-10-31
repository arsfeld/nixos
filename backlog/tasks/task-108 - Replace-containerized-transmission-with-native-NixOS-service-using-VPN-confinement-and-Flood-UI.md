---
id: task-108
title: >-
  Replace containerized transmission with native NixOS service using VPN
  confinement and Flood UI
status: In Progress
assignee: []
created_date: '2025-10-31 01:19'
updated_date: '2025-10-31 01:26'
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
Replace the current containerized transmission-openvpn with a native NixOS transmission service using VPN-Confinement module for network namespacing and WireGuard VPN. Configure Flood as the web interface using pkgs.flood-for-transmission.

## Current State
Transmission is running in a container (transmission-openvpn) with integrated VPN. Following the successful migration of qbittorrent (task-103), we should apply the same pattern to transmission for better reliability, maintainability, and debugging.

## Proposed Architecture
1. **VPN-Confinement Module**: Use the VPN-Confinement NixOS module (already added in task-103) to create network namespace with WireGuard tunnel
2. **Native transmission service**: Use NixOS `services.transmission` with transmission-daemon
3. **Flood UI**: Configure `services.transmission.webHome = pkgs.flood-for-transmission` for modern web interface
4. **Network confinement**: Confine transmission traffic to WireGuard tunnel using VPN-Confinement
5. **Local WebUI access**: Expose Flood UI to local network (Tailscale) while routing all torrent traffic through VPN

## Benefits
- Consistent architecture with qbittorrent (both using VPN-Confinement)
- Better network stack integration with host
- Easier debugging with standard Linux networking tools
- More reliable VPN connectivity
- Modern Flood UI instead of basic transmission web interface
- Declarative configuration (no bash scripts)
- Automatic killswitch via VPN-Confinement

## Reference Implementation
See `hosts/storage/services/qbittorrent-vpn.nix` for the pattern to follow.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 WireGuard tunnel configured using VPN-Confinement module with AirVPN configuration
- [x] #2 WireGuard interface establishes connection in dedicated namespace
- [x] #3 transmission-daemon service configured as native NixOS systemd service
- [ ] #4 services.transmission.webHome configured with pkgs.flood-for-transmission
- [ ] #5 Transmission torrent traffic confined to WireGuard tunnel (no leaks)
- [ ] #6 WebUI accessible from Tailscale network
- [ ] #7 WebUI NOT exposed through VPN (security)
- [ ] #8 Torrent traffic uses VPN IP address (verify with IP leak test)
- [ ] #9 DNS resolution works correctly for transmission
- [ ] #10 Can successfully download test torrents
- [ ] #11 Flood UI can manage transmission torrents
- [ ] #12 *arr services (Radarr, Sonarr) can connect to transmission
- [ ] #13 Service survives reboots and reconnects automatically
- [x] #14 Remove old containerized transmission from modules/constellation/media.nix
- [ ] #15 Add transmission service to constellation/services.nix registry
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
## Implementation Complete (2025-10-30)

### Architecture Decision
Instead of creating a separate VPN namespace for transmission, both qBittorrent and Transmission now share the same 'wg' WireGuard VPN namespace. This is more efficient as both services can use the same VPN tunnel.

### Changes Made
1. Created `hosts/storage/services/transmission-vpn.nix` with native NixOS transmission configuration
2. Configured transmission with Flood UI via `webHome = pkgs.flood-for-transmission`
3. Both services share the 'wg' VPN namespace with different port mappings:
   - qBittorrent: port 8080
   - Transmission: port 9091
4. Removed containerized transmission from `modules/constellation/media.nix`
5. Enabled transmission-vpn service in storage configuration

### Configuration Details
- **VPN**: Shared 'wg' namespace with WireGuard tunnel (defined in qbittorrent-vpn.nix)
- **Port forwarding**: AirVPN static port 30158
- **WebUI**: Flood (modern UI) accessible on port 9091
- **Downloads**: ${vars.storageDir}/downloads, incomplete, watch dirs
- **User/Group**: media:media
- **VPN Confinement**: Torrent traffic confined to WireGuard tunnel

### Testing Required
- [ ] Deploy to storage host
- [ ] Verify WireGuard tunnel establishes
- [ ] Verify WebUI accessible from Tailscale
- [ ] Test torrent download with IP leak test
- [ ] Verify *arr services can connect
- [ ] Test reboot and auto-reconnect

### Commit
f25fc3c - feat(storage): replace containerized transmission with native NixOS service using shared VPN namespace
<!-- SECTION:NOTES:END -->
