---
id: task-157
title: Remove bat-boa.ts.net Authelia instance and consolidate to single instance
status: To Do
assignee: []
created_date: '2025-12-01 21:29'
labels:
  - refactor
  - authelia
  - simplification
dependencies: []
priority: medium
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Having two Authelia instances (arsfeld.one on port 9091 and bat-boa.ts.net on port 63836) is confusing and caused the Immich OIDC bug (task-156) where storage's Caddy was routing to the wrong instance.

## Current State
- `authelia-arsfeld.one` runs on cloud:9091 - handles *.arsfeld.one services
- `authelia-bat-boa.ts.net` runs on cloud:63836 (via nameToPort) - handles *.bat-boa.ts.net services via tsnsrv

## Proposed Changes
1. Remove the bat-boa.ts.net Authelia instance from `hosts/cloud/services/auth.nix`
2. Update tsnsrv services to use the arsfeld.one instance (cloud:9091) for authentication
3. Ensure session cookies work correctly across both domains (may need investigation)
4. Remove the redis instance for bat-boa.ts.net Authelia
5. Clean up any references to the second instance

## Considerations
- Session cookies are domain-scoped - need to verify if a single Authelia can handle both *.arsfeld.one and *.bat-boa.ts.net
- May need to configure Authelia with multiple cookie domains
- Alternative: Keep single instance but ensure consistent routing
<!-- SECTION:DESCRIPTION:END -->
