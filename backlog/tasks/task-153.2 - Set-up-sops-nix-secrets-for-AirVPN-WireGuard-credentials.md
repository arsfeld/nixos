---
id: task-153.2
title: Set up sops-nix secrets for AirVPN WireGuard credentials
status: Done
assignee: []
created_date: '2025-11-30 19:31'
updated_date: '2025-11-30 19:55'
labels:
  - secrets
  - sops-nix
dependencies: []
parent_task_id: task-153
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Create the secret structure in sops-nix for storing AirVPN WireGuard credentials.

## Required Secrets per Exit Node

From AirVPN Config Generator (https://airvpn.org/generator/):
- `WIREGUARD_PRIVATE_KEY` - The private key from the [Interface] section
- `WIREGUARD_PRESHARED_KEY` - The preshared key from the [Peer] section  
- `WIREGUARD_ADDRESSES` - The Address from [Interface] (e.g., `10.141.x.x/32`)

## Secret File Structure

Option A - Separate secrets per value:
```yaml
# secrets/sops/storage.yaml (or common.yaml)
airvpn:
  brazil:
    private-key: "..."
    preshared-key: "..."
    address: "10.141.x.x/32"
  us:
    private-key: "..."
    preshared-key: "..."
    address: "10.141.x.x/32"
```

Option B - Environment file per country:
```yaml
airvpn-brazil-env: |
  WIREGUARD_PRIVATE_KEY=...
  WIREGUARD_PRESHARED_KEY=...
  WIREGUARD_ADDRESSES=10.141.x.x/32
```

## Tailscale Auth Key

Need a dedicated Tailscale auth key for exit nodes:
- Should be reusable (for multiple nodes)
- Consider using tagged auth key for ACL policies

## Tasks

1. Decide on secret structure (Option A vs B)
2. Update .sops.yaml if needed for new secret paths
3. Generate WireGuard config from AirVPN for Brazil
4. Extract and store credentials in sops
5. Create/obtain Tailscale auth key for exit nodes
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Secret structure decided and documented
- [x] #2 At least one country (Brazil) credentials stored in sops
- [ ] #3 Tailscale auth key for exit nodes created and stored
- [x] #4 Secrets accessible from target host (storage)
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Created airvpn-env.age with WIREGUARD_PRIVATE_KEY, WIREGUARD_PRESHARED_KEY, WIREGUARD_ADDRESSES extracted from existing airvpn-wireguard.age config. Using existing tailscale-key.age for Tailscale auth.
<!-- SECTION:NOTES:END -->
