---
id: task-153.7
title: Add documentation for generating AirVPN configs and adding new exit nodes
status: Done
assignee: []
created_date: '2025-11-30 19:31'
updated_date: '2025-11-30 20:47'
labels:
  - documentation
dependencies:
  - task-153.6
parent_task_id: task-153
priority: low
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Document the process for adding new VPN exit nodes, including how to generate AirVPN WireGuard configurations.

## Documentation Location

Add to `CLAUDE.md` under a new section, or create `docs/vpn-exit-nodes.md`.

## Content to Document

### 1. Generating AirVPN WireGuard Config

Step-by-step guide:
1. Log into https://airvpn.org/
2. Go to Config Generator: https://airvpn.org/generator/
3. Select "WireGuard UDP" under Protocols
4. Choose desired country/server
5. Click "Generate" and download .conf file
6. Extract values from the config file

### 2. Extracting Credentials

From the downloaded `.conf` file:
```ini
[Interface]
Address = 10.141.x.x/32    # → WIREGUARD_ADDRESSES
PrivateKey = xxxxx         # → WIREGUARD_PRIVATE_KEY

[Peer]
PresharedKey = xxxxx       # → WIREGUARD_PRESHARED_KEY
```

### 3. Adding Secrets to sops

```bash
nix develop -c sops secrets/sops/storage.yaml
# Add the credentials under airvpn.<country> path
```

### 4. Enabling a New Exit Node

Example NixOS configuration snippet.

### 5. Tailscale Admin Setup

- How to approve exit nodes
- ACL configuration for auto-approval (optional)
- Setting up exit node policies
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Documentation covers AirVPN config generation
- [x] #2 Step-by-step guide for extracting WireGuard credentials
- [x] #3 Instructions for adding secrets to sops
- [x] #4 Example configuration for enabling new exit nodes
- [x] #5 Tailscale admin setup documented
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Documentation added to CLAUDE.md covering:
- Architecture overview
- AirVPN WireGuard config generation
- Credential extraction from .conf files
- Tailscale auth key creation via API
- ragenix secret management
- NixOS configuration examples
- Usage and troubleshooting
<!-- SECTION:NOTES:END -->
