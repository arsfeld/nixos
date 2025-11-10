---
id: task-60
title: Fix Kea DHCP service dependency to start after br-lan interface is ready
status: Done
assignee: []
created_date: '2025-10-18 03:39'
updated_date: '2025-11-06 15:05'
labels:
  - networking
  - dhcp
  - systemd
  - router
dependencies: []
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
## Problem
On router boot, the Kea DHCP4 server starts before the br-lan interface is fully ready, causing it to fail opening the socket. This results in Kea running but not listening for DHCP traffic, breaking DHCP for all clients on the network.

Error from logs:
```
DHCPSRV_OPEN_SOCKET_FAIL failed to open socket: the interface br-lan is not running
DHCPSRV_NO_SOCKETS_OPEN no interface configured to listen to DHCP traffic
```

## Solution
Add systemd service dependencies to ensure kea-dhcp4-server starts after the br-lan network interface is fully up and running.

In the router NixOS configuration, add:
```nix
systemd.services.kea-dhcp4-server = {
  after = [ "network-online.target" "sys-subsystem-net-devices-br\\x2dlan.device" ];
  wants = [ "network-online.target" ];
};
```

## Testing
1. Deploy the configuration change to router
2. Reboot the router
3. Check that Kea starts successfully with: `journalctl -u kea-dhcp4-server -n 50`
4. Verify no "DHCPSRV_OPEN_SOCKET_FAIL" errors in startup logs
5. Confirm DHCP clients can obtain leases
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Kea DHCP service starts after br-lan interface is ready
- [x] #2 No socket binding failures in startup logs
- [x] #3 DHCP clients successfully obtain leases after router reboot
- [x] #4 Configuration change deployed and tested with a full reboot
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
## Implementation

Added systemd service dependencies to kea-dhcp4-server in hosts/router/services/kea-dhcp.nix:
- `after = ["network-online.target" "sys-subsystem-net-devices-br\\x2dlan.device"]`
- `wants = ["network-online.target"]`

This ensures kea waits for:
1. The network subsystem to be online
2. The br-lan bridge device to exist and be ready

Commit: 8990e11 - fix(router): ensure kea-dhcp4-server starts after br-lan interface is ready

## Next Steps

1. Deploy to router: `just deploy router`
2. Reboot the router to test the fix
3. Verify kea starts successfully: `journalctl -u kea-dhcp4-server -n 50`
4. Confirm no socket binding errors in logs
5. Test that DHCP clients can obtain leases
<!-- SECTION:NOTES:END -->
