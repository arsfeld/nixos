---
id: task-9
title: Use Go from nixpkgs-unstable for caddy-tailscale build
status: Done
assignee:
  - '@claude'
created_date: '2025-10-12 16:00'
updated_date: '2025-10-12 16:20'
labels:
  - infrastructure
  - nix
dependencies: []
priority: medium
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Replace the GOTOOLCHAIN workaround in caddy-tailscale package with Go 1.25+ from nixpkgs-unstable. This will eliminate the need for --option sandbox false and make the build fully reproducible without runtime toolchain downloads.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Check if Go 1.25+ is available in nixpkgs-unstable
- [x] #2 Modify caddy-tailscale/default.nix to use buildGo125Module or latest from unstable
- [x] #3 Remove GOTOOLCHAIN overrides and proxyVendor workarounds
- [x] #4 Update go.mod if needed to match the Go version from unstable
- [x] #5 Test build with sandbox enabled (without --option sandbox false)
- [x] #6 Verify all Tailscale modules are still included in the built binary
- [x] #7 Update README.md to remove sandbox disable requirement
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Check nixpkgs-unstable for Go 1.25+ availability
2. Read flake.nix to understand how packages are defined
3. Modify default.nix to use Go 1.25+ from unstable
4. Remove all GOTOOLCHAIN workarounds and proxyVendor
5. Recompute vendorHash with the new Go version
6. Test build with sandbox enabled
7. Verify Tailscale modules in binary
8. Update README.md
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Successfully replaced GOTOOLCHAIN workarounds with Go 1.25.1 from nixpkgs-unstable.

## Changes Made:

1. **Flake Configuration** (flake.nix):
   - Added overlay in perSystem to provide buildGo125Module from nixpkgs-unstable
   - Updated _module.args.pkgs to apply overlays before package loading
   - Added same overlay to flake.lib.overlays for NixOS configurations

2. **Package Definition** (packages/caddy-tailscale/default.nix):
   - Changed from buildGo124Module to pkgs.buildGo125Module
   - Removed all GOTOOLCHAIN workarounds (proxyVendor, overrideModAttrs, preBuild)
   - Simplified to clean, maintainable package definition
   - Updated vendorHash to sha256-rKJu1lt4Qz6Urw3eLw9rULs+gP7xMGpKkJmEYnxUyPQ=

3. **Git Tracking**:
   - Added main.go, go.mod, go.sum to Git (required for Nix source path)

4. **Documentation** (README.md):
   - Updated Build Approach section to reflect new architecture
   - Removed --option sandbox false from build instructions
   - Removed GOTOOLCHAIN-related troubleshooting entries

## Results:

- Build completes successfully in ~30 seconds with sandbox enabled
- All Tailscale modules verified in built binary
- Fully reproducible builds without runtime downloads
- Follows standard Nix patterns and best practices
<!-- SECTION:NOTES:END -->
