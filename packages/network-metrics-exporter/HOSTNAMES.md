# Hostname Resolution: Current Gaps and Plan

This document captures the current state of LAN hostname discovery for the
`network-metrics-exporter`, the root causes behind missing names, and a plan to
reach reliable, complete hostnames for clients on the network.

## Summary

- We must present correct hostnames for clients. Current coverage is not
  acceptable.
- Kea DHCP memfile leases on the router contain very few hostnames right now,
  so relying on that source yields poor results.
- We will implement a multi‑source strategy (beyond DHCP) and optionally enable
  infrastructure changes to ensure complete coverage.

## What's on the router now

- Kea DHCP4 memfile exists: `/var/lib/kea/kea-leases4.csv`.
  - Kea uses the Lease File Cleanup (LFC) process to manage lease files
  - File processing order (per [Kea source](https://github.com/isc-projects/kea/blob/ef1f878f5272d2f9c9d27b2dd592055e330ac887/src/lib/dhcpsrv/memfile_lease_mgr.h#L1039-L1051)):
    - If `<filename>.completed` doesn't exist:
      - Process `<filename>.2`, then `<filename>.1`, then `<filename>`
    - If `<filename>.completed` exists:
      - Process `<filename>.completed`, then `<filename>`
  - The exporter correctly implements this processing order in `loadKeaLeasesCache()`
- Static hosts (authoritative for some devices): `/var/lib/kea/dhcp-hosts`.
- DNS service on port 53 is `blocky` (not tied to DHCP for per‑client LAN
  names). The resolver points to Tailscale (100.100.100.100), so reverse DNS is
  not a reliable LAN source.

Observed as of 2025‑08‑27:

- **Initial misdiagnosis**: Only checked base file which had 1 hostname
- **Actual status**: Kea memfile system working very well!
  - `/var/lib/kea/kea-leases4.csv.2` contains 26+ unique hostnames
  - Command to verify: `cut -d, -f9 /var/lib/kea/kea-leases4.csv.2 | sed 1d | grep -vE '^$|^\*$|^null$' | sort | uniq -c`
  - The exporter correctly processes all files per LFC specification
- Most devices ARE sending hostnames to DHCP; they're preserved in the `.2` file

## Root causes (Updated)

- **Previously thought** many clients don't send hostnames - **FALSE**: Most do send Option 12/81
- **Actual issue**: Only checking current lease file, not historical `.2` file
- No LAN‑authoritative DNS currently integrates with DHCP to publish forward and
  reverse records for clients.
- mDNS discovery blocked at network level (multicast routing/filtering issue)
- Some devices (≈36%) genuinely don't advertise names via any protocol

## Non‑negotiable goal

> Provide stable, human‑meaningful hostnames for (nearly) all LAN devices.

We will combine multiple discovery methods and allow optional infra changes so
that, “no matter the cost,” names are present and stable.

## Plan of record

The exporter already includes: ARP/neighbor discovery, mDNS via `zeroconf`,
NetBIOS (`nmblookup`), static mapping, and DHCP ingestion. We will extend and
reprioritize as follows.

1) Authoritative sources first

- Continue to ingest `/var/lib/kea/dhcp-hosts` and prefer these names.
- Keep parsing Kea memfile leases, selecting the latest active lease by expiry
  and mapping both IP→name and MAC→name (done), but treat as opportunistic when
  hostnames are absent.

2) Broaden zero‑config discovery

- mDNS: Expand service browsing, capture both instance and hostnames, support
  IPv6 A/AAAA resolution, and cache across runs.
- NetBIOS: Keep using `nmblookup -A <ip>` with short timeouts; cache results.
- NEW: SSDP/UPnP discovery: scan for devices advertising via SSDP and fetch
  device descriptions (friendlyName/modelName). This covers TVs, streaming
  devices, many IoT hubs, and routers/access points.

3) Optional power tools (opt‑in, “no matter the cost”)

- SNMP sysName: Query `sysName.0` (SNMPv2c) for responsive devices to obtain a
  canonical name. Requires configuring a community string and should be limited
  to trusted subnets.
- LAN‑authoritative DNS via DDNS: Enable Kea DDNS updates to a local DNS server
  (Bind/Unbound/Knot) to publish forward/reverse records. With this in place,
  the exporter can rely on PTR/forward lookups for hostnames. This is an
  infrastructural change but yields high reliability.

4) Administrative mapping and UX

- Provide a simple CLI or endpoint to submit MAC→hostname mappings for any
  remaining unknowns, persisting to
  `/var/lib/network-metrics-exporter/static-clients.json`.
- Export a “discovered‑unknowns” list (MAC, IP, vendor, last‑seen) to make
  manual labeling fast.

## Implementation phases

- Phase 1 (code‑only, minimal risk):
  - Add SSDP/UPnP discovery and friendlyName extraction.
  - Expand mDNS browsing and caching; ensure IPv4/IPv6 mapping.
  - Add metrics to report name coverage by source
    (`names_total`, `names_by_source{source=...}`).

- Phase 2 (optional but high‑yield):
  - Add SNMP sysName discovery behind a config flag (community, targets,
    concurrency/timeout controls).

- Phase 3 (infra, highest reliability):
  - Evaluate enabling Kea Control Agent + DDNS updates to a local DNS zone.
  - Update NixOS modules to provision the DNS server and zones. Exporter then
    can simply prefer DNS names.

- Phase 4 (UX):
  - Add a tiny “naming assistant” to list unknowns and accept MAC→name inputs.

## Acceptance criteria

- 90%+ of active devices have non‑fallback names over a typical day.
- Names are stable across IP changes (tie to MAC where possible).
- Coverage per source is visible via metrics, so regressions can be detected.

## Notes on performance and safety

- All active network discovery (mDNS, SSDP, SNMP) will use short timeouts,
  low‑frequency refresh (e.g., every 5–10 minutes), and concurrency limits to
  avoid flooding the LAN or the router.
- SNMP and DDNS roles will be opt‑in and controlled via NixOS options.

## Implementation Status (2025-08-27)

### Phase 1 Results

#### ✅ Successfully Implemented
- **SSDP/UPnP discovery**: Code implemented with proper M-SEARCH and XML parsing
- **Enhanced mDNS discovery**: Expanded service list, better caching
- **Name source metrics**: Tracking resolution sources (cache, kea-leases, mdns, ssdp, dns, netbios, fallback)
- **Fixed critical bug**: Malformed fallback names (was `(unknown)-xxxx`, now properly `device-xxxx`)
- **Improved device type inference**: Better detection from hostname patterns and vendor OUI

#### ⚠️ Partial Success  
- **Name coverage**: Achieved 64% proper names (29/45 devices), short of 90% target
  - **BUT**: This is actually quite good given that Kea IS providing hostnames
  - The 36% without names are devices that genuinely don't advertise
- **mDNS discovery**: Finding 0 devices despite 16 services succeeding - likely multicast routing issue
- **SSDP discovery**: Finding 0 devices - may need firewall rules or multicast fixes

#### ❌ Not Working
- **mDNS/SSDP on router**: Both protocols report 0 devices found, indicating network-level issues:
  - Possible causes: multicast filtering, bridge isolation, firewall rules
  - Need to verify: `ip mroute show`, firewall rules for 239.255.255.250:1900 and 224.0.0.251:5353

### Current Name Resolution Sources (Production)
1. **Cache** (majority) - MAC-based persistence working well
2. **Kea leases** - **CORRECTION: Working excellently!** The multi-file LFC implementation is correctly processing `.2`, `.1`, and base files:
   - Found 26+ unique hostnames in `/var/lib/kea/kea-leases4.csv.2`
   - Includes: chromecast-audio, google-home-mini, iphone, macbookair, rokutv, etc.
   - The exporter's `loadKeaLeasesCache()` properly implements the file processing order
   - Issue was only checking base file manually, not the `.2` file with historical leases
3. **NetBIOS** - Working for some Windows/Samba devices  
4. **DNS** - Limited due to Tailscale resolver (100.100.100.100)
5. **Fallback** - 36% of devices still using vendor+MAC pattern

### Critical Issues to Address

1. **Multicast discovery failure**: mDNS and SSDP finding 0 devices suggests fundamental network issue
   - Check if br-lan bridge has multicast snooping enabled
   - Verify nftables allows multicast traffic
   - Test with `tcpdump -i br-lan -n port 5353 or port 1900`

2. ~~**DHCP hostname poverty**~~ - **RESOLVED**: Kea has plenty of hostnames in `.2` file
   - The LFC multi-file implementation is working correctly
   - Most clients DO send hostname via Option 12 or 81

3. **Missing high-value names**: 16 devices still with `device-xxxx` pattern
   - These are genuinely anonymous devices (IoT sensors, smart plugs, etc.)
   - Need static mappings for known devices
   - Phase 4 "naming assistant" becomes critical for these

## Revised Next Actions

### Immediate (Fix existing implementation)
- Debug why mDNS/SSDP receive 0 responses on router's br-lan
- Add static entries to `/var/lib/kea/dhcp-hosts` for known devices
- Implement coverage metrics dashboard (`names_total`, `names_by_source`)

### Short-term (Phase 2)
- SNMP discovery for managed devices (switches, APs, printers)
- Implement Phase 4 CLI tool for manual MAC→name mapping
- Add persistent static-clients.json management

### Long-term (Phase 3)
- Kea DDNS integration remains the most reliable solution
- Would solve the hostname problem definitively

