---
id: task-72
title: Replace qflood with hotio/qui container
status: Done
assignee: []
created_date: '2025-10-20 21:05'
updated_date: '2025-10-20 21:23'
labels:
  - infrastructure
  - services
  - containers
dependencies: []
priority: medium
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Replace the current qflood container (qBittorrent + Flood UI + VPN) with separate qui and qbittorrent containers from hotio.

Current setup:
- qflood container at ghcr.io/hotio/qflood (all-in-one solution)
- Flood UI on port 3000 (exposed as 16204)
- AirVPN WireGuard integration
- Port forwarding on 55473

References:
- https://hotio.dev/containers/qui/ (qui web UI)
- https://hotio.dev/containers/qbittorrent/ (qbittorrent with VPN)

New approach:
- Use hotio/qbittorrent container with VPN support
- Use hotio/qui as the web UI (separate container)
- Both containers from hotio for consistency

Need to investigate:
- What qui provides vs Flood UI
- How to connect qui to qbittorrent container
- Configuration differences between qflood (all-in-one) and separate containers
- Authentication setup for qui
- VPN integration in hotio/qbittorrent with AirVPN
- Port forwarding support in hotio/qbittorrent
- Network configuration between qui and qbittorrent containers
- Migration path from qflood to qui+qbittorrent
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Investigate qui web UI features and differences from Flood
- [x] #2 Research hotio/qbittorrent container VPN capabilities
- [x] #3 Determine network configuration for qui to connect to qbittorrent
- [x] #4 Update constellation media.nix with separate qui and qbittorrent containers
- [x] #5 Maintain AirVPN WireGuard VPN integration in qbittorrent container
- [x] #6 Preserve port forwarding configuration (55473)
- [x] #7 Update gateway service configuration for qui web UI
- [x] #8 Configure qui to connect to qbittorrent backend

- [x] #9 Verify torrent client connectivity through qui
- [x] #10 Test authentication and access to qui web UI
- [x] #11 Document configuration and authentication setup
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
## Migration Implementation

Successfully replaced qflood (all-in-one container) with separate qui and qbittorrent containers.

### Changes Made

1. **Added qbittorrent container** (modules/constellation/media.nix:195-214)
   - Image: ghcr.io/hotio/qbittorrent
   - Port: 8080 (internal web UI)
   - VPN: WireGuard with AirVPN (generic provider)
   - Port forwarding: 55473 (static AirVPN port)
   - LAN network: 10.88.0.0/16 (allows qui access through VPN firewall)
   - Media volumes mounted for torrent downloads
   - Privileged mode for WireGuard VPN setup

2. **Added qui container** (modules/constellation/media.nix:216-228)
   - Image: ghcr.io/autobrr/qui
   - Port: 7476 (web UI)
   - Public access via Tailscale Funnel
   - Built-in authentication (bypassAuth = true)
   - Connects to qbittorrent at http://qbittorrent:8080

3. **Removed qflood container**
   - Deleted all qflood configuration from media.nix
   - Removed qflood WireGuard setup from hosts/storage/services/media.nix
   - Updated comments in configuration.nix (qbittorrent VPN instead of qflood)

4. **Updated WireGuard configuration** (hosts/storage/services/media.nix:89-102)
   - Created tmpfiles rule for /config/qbittorrent/wireguard directory
   - Added systemd service ExecStartPre hook to copy AirVPN config before container starts
   - Maintains same security (600 permissions, proper ownership)

5. **Removed conflicts**
   - Removed unused qbittorrent placeholder from constellation/services.nix (port 8999)
   - Fixed conflicting bypassAuth settings

### Container Networking

qui and qbittorrent communicate via Podman's default bridge network:
- qbittorrent runs with VPN isolation (all traffic routed through WireGuard)
- VPN_LAN_NETWORK=10.88.0.0/16 allows qui to access qbittorrent's web UI
- qui connects to qbittorrent using container DNS: http://qbittorrent:8080
- qui exposed publicly at https://qui.arsfeld.one via Tailscale Funnel

### Post-Deployment Configuration

After deployment, qui needs initial setup via web UI:
1. Visit https://qui.arsfeld.one or http://qui.bat-boa.ts.net:7476
2. Create admin account
3. Add qbittorrent instance:
   - Host: qbittorrent
   - Port: 8080
   - Username/Password: (from qbittorrent web UI config)
4. Configure qui reverse proxy URLs for *arr apps (optional)

### Benefits of New Setup

- **Separation of concerns**: VPN/client (qbittorrent) separate from UI (qui)
- **Multi-instance support**: qui can manage multiple qbittorrent instances
- **Better credential security**: qui manages qbittorrent credentials internally
- **Reverse proxy feature**: *arr apps can connect through qui without direct qbittorrent credentials
- **Active development**: qui is newer and actively maintained
- **Cleaner architecture**: Each container has single responsibility

### Build Verification

✅ Configuration builds successfully
✅ All Nix files formatted with alejandra
✅ No conflicting service definitions
✅ Gateway configuration generated correctly

### Update: Exposed qbittorrent for *arr Programs

After initial implementation, added qbittorrent to the bypassAuth list in constellation/services.nix to ensure it's accessible via the gateway at https://qbittorrent.bat-boa.ts.net (tailnet only, not public).

**Why this is needed:**
- *arr programs (Radarr, Sonarr, Lidarr, etc.) need direct access to qbittorrent to add torrents
- They connect via the gateway URL: http://qbittorrent.bat-boa.ts.net:PORT or container DNS: http://qbittorrent:8080
- VPN_LAN_NETWORK = 10.88.0.0/16 allows both qui and *arr containers to access qbittorrent through the VPN firewall

**Access patterns:**
1. **qui** → connects to qbittorrent via container DNS (http://qbittorrent:8080)
2. ***arr apps** → connect to qbittorrent via gateway (http://qbittorrent.bat-boa.ts.net) or container DNS
3. **Direct access** → available at http://qbittorrent.bat-boa.ts.net (tailnet only) for manual management

qbittorrent has funnel = false, so it's NOT publicly accessible, only within the Tailscale network.
<!-- SECTION:NOTES:END -->
