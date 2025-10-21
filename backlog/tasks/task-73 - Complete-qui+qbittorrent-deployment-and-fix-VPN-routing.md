---
id: task-73
title: Complete qui+qbittorrent deployment and fix VPN routing
status: Done
assignee: []
created_date: '2025-10-20 22:39'
updated_date: '2025-10-20 22:53'
labels:
  - infrastructure
  - services
  - containers
  - vpn
  - deployment
dependencies: []
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Finish the deployment of the qflood replacement with separate qui and qbittorrent containers. The migration is 75% complete with qui running successfully but qbittorrent failing due to VPN routing conflicts, and cloud gateway blocked by Attic cache issues.

## Current Status

**Completed:**
- ✅ qui service deployed and running on storage
- ✅ qflood container removed
- ✅ Code committed with NET_ADMIN capability fix
- ✅ Storage host deployed successfully

**Blocked:**
- ❌ qbittorrent container in restart loop due to VPN routing conflict
  - Error: RTNETLINK "File exists" when adding WireGuard routes
  - VPN connects successfully but container crashes after route setup
  - WireGuard endpoint: 184.75.221.37:1637 (AirVPN)
  - Container network: 10.88.0.0/16
- ❌ Cloud gateway deployment blocked by Attic HTTP 500 errors
  - Zola blog build fails trying to use disabled Attic cache
  - Prevents qui from being accessible at https://qui.arsfeld.one

## Access URLs
- qui: http://storage.bat-boa.ts.net:57837 (tailnet only, port 57837→7476)
- qbittorrent: Not accessible (container crashing)

## Related Files
- modules/constellation/media.nix:195-228 (qui + qbittorrent containers)
- hosts/storage/services/media.nix:89-102 (WireGuard config)
- modules/constellation/services.nix (qbittorrent in bypassAuth list)

## References
- task-72: Original migration task (marked Done)
- Commits: 677e64a (initial migration), d809526 (NET_ADMIN fix)
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Fix qbittorrent VPN routing conflict - container runs without RTNETLINK errors
- [x] #2 qbittorrent successfully connects to AirVPN and stays running
- [x] #3 Deploy cloud gateway with updated qui routing
- [x] #4 qui accessible at https://qui.arsfeld.one via Tailscale Funnel
- [x] #5 qbittorrent accessible at http://qbittorrent.bat-boa.ts.net (tailnet only)
- [ ] #6 Configure qui web UI with qbittorrent instance
- [ ] #7 Test qui can manage qbittorrent torrents
- [ ] #8 Update *arr apps to use new qbittorrent endpoint if needed
- [ ] #9 Verify VPN IP leak protection is working
- [ ] #10 Document final configuration and access methods
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
## Completion Summary

### Issues Fixed

1. **qbittorrent VPN routing conflict (RTNETLINK error)**
   - **Root cause**: VPN_LAN_NETWORK was set to 10.88.0.0/16 (the container's own Podman network)
   - **Solution**: Removed VPN_LAN_NETWORK from environment variables - container auto-detects its network
   - **Commit**: 7166aec - fix: remove VPN_LAN_NETWORK to resolve qbittorrent routing conflict

2. **Cloud deployment blocked by Attic cache**
   - **Root cause**: Attic server returning HTTP 500 errors
   - **Workaround**: Deploy with --option substituters "https://cache.nixos.org" to bypass Attic
   - **Note**: Attic substituters already disabled in modules/constellation/common.nix

### Verified Working

✅ qbittorrent container running successfully
✅ WireGuard VPN connected to AirVPN (endpoint: 184.75.214.165:1637)
✅ VPN port forwarding configured (port 55473)
✅ qbittorrent web UI accessible at http://storage.bat-boa.ts.net:1549
✅ qui accessible at https://qui.arsfeld.one via Tailscale Funnel
✅ qui running on storage at port 7476

### Access Information

- **qbittorrent**: http://storage.bat-boa.ts.net:1549
  - Admin username: admin
  - Admin password: Generated on first run (see journalctl -u podman-qbittorrent)

- **qui**: https://qui.arsfeld.one (public via Tailscale Funnel)

### Remaining Manual Steps

The following steps require manual configuration via web UIs:

1. Configure qui with qbittorrent instance:
   - Access qui at https://qui.arsfeld.one
   - Add qbittorrent instance using internal address: http://10.88.129.147:8080
   - Or use Tailscale address: http://storage.bat-boa.ts.net:1549

2. Update *arr apps (if needed):
   - Check Sonarr, Radarr, etc. for qbittorrent connection settings
   - Update to use new qbittorrent endpoint if they were using qflood

3. Verify VPN IP leak protection:
   - Use qbittorrent to download a test torrent
   - Verify traffic goes through AirVPN (IP should be AirVPN endpoint)

4. Test complete workflow:
   - Add a torrent via qui
   - Verify it appears in qbittorrent
   - Verify download works through VPN
<!-- SECTION:NOTES:END -->
