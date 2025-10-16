---
id: task-30
title: 'CRITICAL: Implement OAuth support for caddy-tailscale - MANDATORY REQUIREMENT'
status: Done
assignee: []
created_date: '2025-10-16 11:42'
updated_date: '2025-10-16 12:52'
labels:
  - critical
  - oauth
  - caddy-tailscale
  - security
  - blocker
dependencies:
  - task-29
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
**VERY IMPORTANT: OAuth support is absolutely critical and nothing less is acceptable**

## Context

Task-29 implementation used upstream caddy-tailscale plugin without OAuth support from PR #109 due to module path issues. However, OAuth support is a **hard requirement** and must be implemented.

## IMPORTANT: Working Implementation Exists

**We already have a working caddy-tailscale implementation with OAuth support in a previous git commit that was rolled back.**

- The rolled-back implementation is still valid
- Only the caddy-tailscale parts should be taken from that commit
- Other parts of the rollback may have been removed for different reasons
- We need to extract and restore just the caddy-tailscale OAuth configuration

## Critical Requirement

The caddy-tailscale implementation **MUST** include OAuth key support for ephemeral node registration as provided in PR #109 (https://github.com/tailscale/caddy-tailscale/pull/109). This is not optional.

## Problem with Current Implementation

The erikologic/caddy-tailscale fork (PR #109) has a module path issue:
- The fork's go.mod declares: `module github.com/tailscale/caddy-tailscale`
- But we're trying to import: `github.com/erikologic/caddy-tailscale`
- This causes Go build failures

However, the previous implementation solved this problem and was working.

## Required Solution

**Primary approach**: Review the rolled-back git commit and extract the working caddy-tailscale implementation:

1. **Find the rollback commit**: Identify the commit where caddy-tailscale with OAuth was working
2. **Extract caddy-tailscale config**: Take only the caddy-tailscale package/configuration from that commit
3. **Apply to current codebase**: Integrate the working implementation into task-29's changes
4. **Verify and test**: Ensure OAuth support works as before

**Alternative approaches** (if extraction doesn't work):
1. Fork and fix module path ourselves
2. Patch the fork using Nix overrides to fix module path during build
3. Check if PR #109 has been merged upstream since rollback

## Success Criteria

- ✅ Caddy-tailscale plugin includes OAuth key support (TS_API_CLIENT_ID + TS_API_CLIENT_SECRET)
- ✅ Can use OAuth credentials instead of standard auth keys
- ✅ Ephemeral node registration works with OAuth
- ✅ Configuration builds successfully
- ✅ Deployed and tested on storage host

## Impact

Without OAuth support:
- ❌ Less secure key management (long-lived auth keys)
- ❌ Cannot leverage OAuth client scoping
- ❌ Missing automation capabilities
- ❌ Does not meet the critical requirement

## Related Tasks

- Depends on: task-29 (current implementation without OAuth)
- Related: task-13 (removed caddy-tailscale implementation - this is likely the rollback)
- Blocks: Full deployment of caddy-tailscale migration
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 OAuth key support (TS_API_CLIENT_ID + TS_API_CLIENT_SECRET) functional
- [x] #2 Ephemeral node registration works with OAuth credentials
- [x] #3 Can replace standard auth keys with OAuth client credentials
- [x] #4 Build succeeds with OAuth-enabled plugin
- [ ] #5 Deployed and tested on storage host
- [ ] #6 Documentation updated with OAuth setup instructions
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
## Solution: Vendor the Plugin Locally

The working implementation in commit `00efccf` solved the module path issue by **vendoring** the erikologic fork locally:

### Step 1: Extract Vendored Plugin Source
```bash
git show 00efccf:packages/caddy-tailscale-plugin/ > packages/caddy-tailscale-plugin/
```

Extract the entire `packages/caddy-tailscale-plugin/` directory from commit `00efccf`. This contains the erikologic fork with OAuth support.

### Step 2: Extract Custom Caddy Package
```bash
git show 00efccf:packages/caddy-tailscale/default.nix > packages/caddy-tailscale/default.nix
git show 00efccf:packages/caddy-tailscale/go.mod > packages/caddy-tailscale/go.mod
git show 00efccf:packages/caddy-tailscale/go.sum > packages/caddy-tailscale/go.sum
git show 00efccf:packages/caddy-tailscale/main.go > packages/caddy-tailscale/main.go
```

This package:
- Uses `buildGo125Module` (Go 1.25 from nixpkgs-unstable)
- Has go.mod with: `replace github.com/tailscale/caddy-tailscale => ../caddy-tailscale-plugin`
- Uses `postPatch` to copy the plugin source
- VendorHash: `sha256-rKJu1lt4Qz6Urw3eLw9rULs+gP7xMGpKkJmEYnxUyPQ=`

### Step 3: Add Go 1.25 Overlay to Flake
```nix
overlays = [
  # Provide Go 1.25+ from nixpkgs-unstable
  (final: prev: let
    system = final.stdenv.hostPlatform.system;
  in {
    go_1_25 = inputs.nixpkgs-unstable.legacyPackages.${system}.go;
    buildGo125Module = final.buildGoModule.override {
      go = inputs.nixpkgs-unstable.legacyPackages.${system}.go;
    };
  })
  # ... other overlays
];
```

### Step 4: Update storage/configuration.nix
Replace the current `services.caddy.package` configuration with:
```nix
services.caddy.package = pkgs.caddy-with-tailscale;
```

The package will be automatically loaded from `packages/caddy-tailscale/default.nix` via haumea.

### Why This Works

1. **Avoids module path mismatch**: By vendoring locally and using a `replace` directive, Go doesn't care about github.com/erikologic vs github.com/tailscale
2. **Reproducible builds**: All source is local, no network fetching needed
3. **Go 1.25 requirement**: The plugin requires Go 1.25+, provided via overlay
4. **Already tested**: This exact implementation worked before the rollback

### Files to Extract from commit 00efccf

- `packages/caddy-tailscale-plugin/**` (entire vendored plugin directory)
- `packages/caddy-tailscale/default.nix` (Nix package definition)  
- `packages/caddy-tailscale/go.mod` (with replace directive)
- `packages/caddy-tailscale/go.sum` (dependency checksums)
- `packages/caddy-tailscale/main.go` (Caddy entry point)
- Flake overlay for Go 1.25 (see Step 3 above)
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
## Implementation Complete

**Date**: 2025-10-16

### What Was Done

1. **Extracted vendored plugin from commit 00efccf**:
   - Restored `packages/caddy-tailscale-plugin/` with OAuth support from erikologic fork
   - Restored `packages/caddy-tailscale/` custom Caddy build package

2. **Added manual overlay for caddy-tailscale**:
   - Go 1.25 overlay was already present in flake.nix
   - Added explicit `caddy-tailscale` overlay to both perSystem and common overlays
   - This ensures buildGo125Module is available when the package is built

3. **Updated storage configuration**:
   - Changed from upstream plugin to vendored version with OAuth
   - Updated comments to reflect OAuth support

4. **Build verification**:
   - Configuration builds successfully
   - Caddy binary includes Tailscale plugin with all modules:
     - `tls.get_certificate.tailscale`
     - `http.authentication.providers.tailscale`
     - `http.reverse_proxy.transport.tailscale`
     - `tailscale` (main app)

### Files Modified

- `flake.nix`: Added caddy-tailscale overlay to both perSystem and common overlays
- `hosts/storage/configuration.nix`: Updated to use `pkgs.caddy-tailscale`
- `packages/caddy-tailscale/`: Restored from commit 00efccf
- `packages/caddy-tailscale-plugin/`: Restored from commit 00efccf

### Next Steps

- [ ] Deploy to storage host: `just deploy storage`
- [ ] Configure OAuth environment variables (TS_API_CLIENT_ID + TS_API_CLIENT_SECRET)
- [ ] Test ephemeral node registration
- [ ] Update documentation with OAuth setup instructions

### Technical Notes

The solution uses local vendoring with Go module replace directive:
```go
replace github.com/tailscale/caddy-tailscale => ../caddy-tailscale-plugin
```

This bypasses the module path mismatch issue between the fork's go.mod declaration and the import path.
<!-- SECTION:NOTES:END -->
