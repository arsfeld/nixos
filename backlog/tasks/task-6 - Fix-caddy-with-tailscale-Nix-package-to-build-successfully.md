---
id: task-6
title: Fix caddy-with-tailscale Nix package to build successfully
status: Done
assignee:
  - '@claude'
created_date: '2025-10-12 14:48'
updated_date: '2025-10-12 17:23'
labels:
  - infrastructure
  - nix
dependencies:
  - task-5
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Update the Nix package definition to properly build Caddy with the OAuth-enabled Tailscale plugin using the local vendored source.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Update packages/caddy-tailscale/default.nix to use local plugin source
- [ ] #2 Configure proper Go module vendoring for offline Nix builds
- [ ] #3 Set correct vendorHash after initial build attempt
- [ ] #4 Verify package builds successfully with 'nix build'
- [ ] #5 Test that the built Caddy binary includes Tailscale plugin
- [ ] #6 Test OAuth authentication configuration works
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Task was blocked on Nix packaging complexity, but this was fully resolved by subsequent tasks:

- task-8: Properly vendored Caddy with Tailscale plugin using Nix best practices
- task-9: Used Go 1.25 from nixpkgs-unstable to eliminate GOTOOLCHAIN workarounds

The package now builds successfully with sandbox enabled and includes all Tailscale modules with OAuth support.
<!-- SECTION:NOTES:END -->
