---
id: task-50
title: >-
  Investigate why router dashboard shows dietpi as "02:00:66" instead of
  hostname
status: Done
assignee:
  - '@claude'
created_date: '2025-10-16 20:26'
updated_date: '2025-10-16 20:35'
labels:
  - bug
  - router
  - networking
  - dashboard
dependencies: []
priority: medium
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
The router dashboard at https://router.bat-boa.ts.net/ is displaying dietpi's MAC address prefix "02:00:66" instead of the hostname "dietpi".

**Current State:**
- dietpi has IP 10.1.1.65 and MAC 02:00:66:98:78:5d
- Hostname is properly set in Kea DHCP lease
- Hostname appears in /var/lib/network-metrics-exporter/hosts as "10.1.1.65 dietpi dietpi.lan"
- Router dashboard is showing "02:00:66" instead of "dietpi"

**Related Issues:**
- Kea's dhcp-hosts hook script may not be updating /var/lib/kea/dhcp-hosts properly with dynamic leases
- Blocky DNS is configured to read from /var/lib/kea/dhcp-hosts, but it's not being populated with dynamic clients

**Files to Check:**
- hosts/router/services/kea-dhcp.nix (Kea hook script configuration)
- hosts/router/services/router-dashboard.nix (dashboard hostname resolution)
- /var/lib/kea/dhcp-hosts (currently only has static entries)
- /var/lib/network-metrics-exporter/hosts (has correct hostname)
<!-- SECTION:DESCRIPTION:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
## Investigation Summary

**Root Cause:**
The network-metrics-exporter had a stale cache that was preventing proper hostname resolution for dietpi (10.1.1.65). The hostname WAS in Kea DHCP leases, but the exporter wasn't finding it during lookups.

**Solution:**
Cleared the stale cache and restarted the exporter:
```bash
rm /var/lib/network-metrics-exporter/client-names.cache
systemctl restart network-metrics-exporter
```

**Result:**
- Metric now shows: `client_status{client="dietpi",ip="10.1.1.65"}`
- Dashboard now displays "dietpi" instead of "02:00:66"

**Files Checked:**
- Kea lease file contains: `10.1.1.65,...,dietpi` (valid)
- Exporter hosts file: `10.1.1.65 dietpi dietpi.lan` (correct)
- Cache was stale and needed refresh

**Note:** The related issue about /var/lib/kea/dhcp-hosts not having dynamic entries is a separate concern - the exporter correctly reads from Kea memfile leases which DO contain dynamic hostnames.
<!-- SECTION:NOTES:END -->
