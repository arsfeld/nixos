---
id: task-107
title: Test and validate native qbittorrent-nox with WireGuard VPN implementation
status: To Do
assignee: []
created_date: '2025-10-31 01:02'
labels:
  - testing
  - infrastructure
  - vpn
  - networking
  - storage
  - qbittorrent
dependencies: []
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Deploy and validate the native NixOS qbittorrent-nox service with WireGuard VPN in network namespace (task-103 implementation). Verify all functionality works correctly and meets acceptance criteria.

## Background
Task-103 implementation is complete and builds successfully. The containerized qbittorrent has been replaced with:
- Native qbittorrent-nox systemd service
- WireGuard VPN in isolated network namespace
- Veth pair for WebUI access from host
- All torrent traffic confined to VPN tunnel

Implementation commit: c5ffc19

## Testing Required
1. Deploy configuration to storage host
2. Verify WireGuard tunnel establishes and maintains connection
3. Test WebUI accessibility from local network and Tailscale
4. Verify torrent traffic uses VPN IP (IP leak test)
5. Test qui and *arr services can connect to qbittorrent
6. Test downloads work correctly
7. Verify service survives reboot and auto-reconnects
8. Monitor for any DNS resolution issues

## Rollback Plan
If issues occur, revert commit c5ffc19 to restore containerized qbittorrent.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Deploy to storage host completes successfully
- [ ] #2 wireguard-vpn-namespace service starts and WireGuard handshake succeeds
- [ ] #3 qbittorrent-nox service starts in VPN namespace
- [ ] #4 WebUI accessible at http://storage.bat-boa.ts.net:8080 and http://qbittorrent.arsfeld.one
- [ ] #5 IP leak test shows VPN IP (10.147.136.54), not host IP
- [ ] #6 DNS resolution works correctly for torrent trackers
- [ ] #7 Test torrent downloads successfully
- [ ] #8 qui can connect to qbittorrent instance at 10.200.200.2:8080
- [ ] #9 Radarr/Sonarr can connect to qbittorrent
- [ ] #10 Service survives reboot and auto-reconnects to VPN
- [ ] #11 No VPN leaks detected (killswitch working)
- [ ] #12 Port 8080 NOT exposed through VPN (security check)
<!-- AC:END -->
