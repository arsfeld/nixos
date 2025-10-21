---
id: task-75
title: Deploy Harmonia cache on raider and integrate across hosts
status: In Progress
assignee: []
created_date: '2025-10-21 01:59'
updated_date: '2025-10-21 02:31'
labels:
  - infrastructure
  - nix
  - cache
dependencies: []
priority: medium
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Provision a harmonia binary cache service on the raider host so it can serve local Nix store artifacts to the rest of the fleet. Ensure the service is built from nix-community/harmonia, runs under systemd, and exposes a secure HTTP endpoint. Update nix settings so other hosts automatically use raider as a substituter, and document any required credentials or firewall changes. Keep existing Attic workflows intact until Harmonia is validated.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Harmonia service is defined and enabled in raider's NixOS configuration with appropriate storage location and retention policy.
- [ ] #2 Service listens on the expected port, passes health checks, and survives reboot on raider.
- [ ] #3 At least one additional host successfully fetches a derivation from the new Harmonia cache during a build.
- [ ] #4 Documented configuration changes for raider and downstream hosts, including any credentials, firewall, or DNS updates.
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Initial Harmonia service configuration is in place (see hosts/raider/harmonia.nix). Added substituters + trusted key in modules/constellation/common.nix and documented usage in docs/guides/harmonia-cache.md. Deployment/validation on raider plus remote fetch verification still pending.
<!-- SECTION:NOTES:END -->
