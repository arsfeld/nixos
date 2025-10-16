---
id: task-51
title: Fix router dashboard WAN IP address showing as "unknown"
status: Done
assignee: []
created_date: '2025-10-16 20:30'
updated_date: '2025-10-16 21:13'
labels:
  - bug
  - router
  - network
dependencies: []
priority: medium
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
The router dashboard at hosts/router/services/router-dashboard.py is currently showing "WAN Address: unknown" instead of the actual public IP address.

The get_wan_ip() method (line 1848) attempts to retrieve the WAN IP from various interfaces (ppp0, eth0, wan, enp1s0) but is failing to find the correct interface or the IP address on those interfaces.

Need to investigate:
1. Which interface is actually being used for WAN connectivity on the router
2. Why the current interface detection logic is failing
3. Consider alternative approaches like querying external IP check services or using a different method to determine the public IP

The method should reliably return the router's public-facing IP address.
<!-- SECTION:DESCRIPTION:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
Found the root cause: WAN interface is enp2s0 but get_wan_ip() only checks ppp0, eth0, wan, enp1s0

Will add enp2s0 to the interface check list and also consider using external IP check as a fallback for reliability
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Fixed get_wan_ip() method by adding enp2s0 (actual WAN interface) to the interface check list

Added external IP check fallback using ifconfig.me with 2-second timeout for reliability

Added curl to router system packages to support the external IP fallback

Changes made in hosts/router/services/router-dashboard.py:1848 and hosts/router/configuration.nix:53
<!-- SECTION:NOTES:END -->
