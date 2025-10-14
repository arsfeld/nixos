---
id: task-5
title: Create local fork of caddy-tailscale with OAuth support
status: Done
assignee:
  - '@claude'
created_date: '2025-10-12 14:48'
updated_date: '2025-10-12 14:54'
labels:
  - infrastructure
  - nix
dependencies:
  - task-4
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Vendor the caddy-tailscale plugin with OAuth support into this repository. This avoids build-time network dependencies and gives us control over the implementation.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Create packages/caddy-tailscale-plugin/ directory structure
- [x] #2 Download and vendor the OAuth-enabled caddy-tailscale source code
- [x] #3 Ensure all dependencies are properly vendored for Nix build
- [x] #4 Add LICENSE and attribution for the upstream project
- [x] #5 Document the fork reason and upstream tracking in README
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
## Vendored Plugin Details
- Source: erikologic/caddy-tailscale@main (Sept 19, 2025)
- Location: packages/caddy-tailscale-plugin/
- Module path: github.com/tailscale/caddy-tailscale
- Go version: 1.25.1
- Key dependencies: Caddy v2.9.1, Tailscale v1.88.2
- OAuth support: TS_API_CLIENT_ID + TS_AUTHKEY environment variables
- Documentation: VENDORED_README.md explains the vendoring reason and upstream tracking
<!-- SECTION:NOTES:END -->
