---
id: task-153
title: Create reusable NixOS module for Tailscale VPN exit nodes via AirVPN
status: In Progress
assignee: []
created_date: '2025-11-30 19:30'
updated_date: '2025-11-30 20:57'
labels:
  - feature
  - tailscale
  - vpn
  - module
dependencies: []
priority: medium
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
## Overview

Create a reusable NixOS module that allows defining multiple Tailscale exit nodes that route traffic through AirVPN WireGuard tunnels. This enables Tailscale clients to use different country exit points (Brazil, US, Europe, etc.) for their internet traffic.

## Architecture

```
[Tailscale Client] → [Tailscale Exit Node Container] → [Gluetun Container] → [AirVPN WireGuard] → [Internet]
```

The module will use:
- **Gluetun** (`qmcgaw/gluetun`) - VPN client container with native AirVPN support
- **Tailscale** (`tailscale/tailscale`) - Running in gluetun's network namespace, advertising as exit node

## Gluetun + AirVPN Configuration

Gluetun has native AirVPN support. Required environment variables for WireGuard:
- `VPN_SERVICE_PROVIDER=airvpn`
- `VPN_TYPE=wireguard`
- `WIREGUARD_PRIVATE_KEY` - from AirVPN Config Generator
- `WIREGUARD_PRESHARED_KEY` - from AirVPN Config Generator
- `WIREGUARD_ADDRESSES` - IPv4 address (e.g., `10.x.x.x/32`)

Server filtering options:
- `SERVER_COUNTRIES` - e.g., "Brazil", "United States"
- `SERVER_REGIONS` - e.g., "South America", "Europe"
- `SERVER_CITIES` - e.g., "Sao Paulo", "Amsterdam"

## WireGuard Config Generation

AirVPN does NOT have a public API for config generation. Configs must be generated manually:
1. Go to https://airvpn.org/generator/
2. Select "WireGuard UDP" under Protocols
3. Select desired server/country
4. Click "Generate" and download .conf file
5. Extract the private key, preshared key, and address values

## Module Design Goals

1. **Declarative configuration** - Define exit nodes in NixOS config
2. **Secret management** - Integrate with sops-nix for WireGuard credentials
3. **Multiple exit nodes** - Easy to add Brazil, US, Europe, etc.
4. **Automatic Tailscale auth** - Use auth keys from secrets
5. **Health monitoring** - Ensure VPN connectivity before advertising exit node

## References

- [Gluetun AirVPN Wiki](https://github.com/qdm12/gluetun-wiki/blob/main/setup/providers/airvpn.md)
- [AirVPN Config Generator](https://airvpn.org/generator/)
- [Gluetun GitHub](https://github.com/qdm12/gluetun)
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Module allows defining multiple VPN exit nodes declaratively
- [x] #2 Each exit node connects to AirVPN via WireGuard through gluetun
- [x] #3 Each exit node runs Tailscale and advertises as exit node
- [x] #4 Secrets (WireGuard keys, Tailscale auth) managed via sops-nix
- [x] #5 Exit nodes appear in Tailscale admin console and can be selected by clients
- [x] #6 Documentation includes how to generate AirVPN WireGuard configs
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Module implemented at modules/constellation/vpn-exit-nodes.nix. Supports both credentialsFile (env format for gluetun server selection) and wireguardConfigFile (custom config). Deployed to storage with Brazil exit node. VPN connecting successfully but healthcheck/Tailscale container needs debugging.

## First Exit Node Working (2025-11-30)

Brazil exit node successfully deployed and tested. Key learnings:

1. **Auth key requirements**: Must use auth key with `tag:exit` and exit node pre-approval via Tailscale ACLs
2. **Container permissions**: Tailscale container needs `--cap-add=NET_ADMIN` and `--device=/dev/net/tun`
3. **Tags**: Must advertise `--advertise-tags=tag:exit` matching the auth key

Remaining: Documentation task (task-153.7)

## Issue Found (2025-11-30)

Exit node is registered but may not be working for clients. Created task-153.8 to investigate routing issues.
<!-- SECTION:NOTES:END -->
