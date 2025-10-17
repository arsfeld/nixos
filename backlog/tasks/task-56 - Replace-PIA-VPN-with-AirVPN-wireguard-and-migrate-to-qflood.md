---
id: task-56
title: Replace PIA VPN with AirVPN wireguard and migrate to qflood
status: In Progress
assignee:
  - '@claude'
created_date: '2025-10-17 14:55'
updated_date: '2025-10-17 17:21'
labels:
  - infrastructure
  - vpn
  - services
dependencies: []
priority: medium
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Replace the current Private Internet Access (PIA) VPN setup with AirVPN using wireguard protocol. At the same time, migrate the current torrent setup to qflood which has integrated VPN support through Gluetun.

Reference: https://engels74.net/containers/qflood/

qflood combines:
- qBittorrent for torrenting
- Gluetun for VPN connectivity (supports AirVPN wireguard)
- Built-in health checks and automatic VPN failover

This consolidates VPN and torrenting into a single integrated solution.
<!-- SECTION:DESCRIPTION:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
## Progress Update

### Completed
- ✅ Created encrypted AirVPN WireGuard configuration secret
- ✅ Integrated qflood into constellation media module
- ✅ Configured port forwarding for AirVPN port 55473
- ✅ WireGuard successfully connects to ca3.vpn.airdns.org:1637
- ✅ Container gets correct AirVPN IPs (10.147.136.54, fd7d:76ee:e68f:a993:9629:b244:b172:19ec)
- ✅ Gateway integration configured (https://qflood.arsfeld.one on port 16204)
- ✅ Split AllowedIPs to avoid raw iptables table requirement
- ✅ Added required sysctl settings (net.ipv4.conf.all.src_valid_mark=1)

### Current Issue
Container fails during startup with:
```
iptables v1.8.9 (legacy): can't initialize iptables table 'filter': Table does not exist
```

WireGuard VPN connects successfully, but container crashes when trying to configure iptables firewall rules. This appears to be a Podman container limitation even with privileged mode.

### Next Steps
1. Investigate kernel module requirements (iptable_filter, etc.)
2. Consider alternative: gluetun + qBittorrent as separate containers
3. Check if Docker runtime handles iptables differently than Podman
4. Review qflood GitHub issues for similar problems
<!-- SECTION:NOTES:END -->
