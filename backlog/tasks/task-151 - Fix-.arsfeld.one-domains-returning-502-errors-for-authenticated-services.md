---
id: task-151
title: Fix *.arsfeld.one domains returning 502 errors for authenticated services
status: Done
assignee: []
created_date: '2025-11-21 03:13'
updated_date: '2025-11-21 03:37'
labels:
  - bug
  - authentication
  - cloud
  - caddy
  - authelia
dependencies: []
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Services accessed via *.arsfeld.one domains (e.g., stash.arsfeld.one, yarr.arsfeld.one) are returning 502 Bad Gateway errors even after Cloudflare cache expiration. The corresponding *.bat-boa.ts.net domains work correctly (e.g., stash.bat-boa.ts.net returns 401 with auth redirect).

## Symptoms:
- External access to https://stash.arsfeld.one → 502 Bad Gateway (served from GitHub error page)
- External access to https://yarr.arsfeld.one → 502 Bad Gateway (served from GitHub error page)
- Access from cloud to https://stash.arsfeld.one → 400 Bad Request
- Direct access to backend (storage:9999) → 200 OK (working)
- Tailscale access (stash.bat-boa.ts.net) → 401 Unauthorized (correct auth behavior)

## Evidence:
Response headers show GitHub Pages error page being served:
```
server: Caddy
server: GitHub.com
via: 1.1 varnish
x-cache: HIT
```

Backend connectivity is confirmed working:
- cloud → storage:9999 returns 200 OK
- authelia-arsfeld.one is running and responding
- Caddy forward_auth endpoint updated to /api/authz/forward-auth

## Possible Root Causes:
1. Cloudflare DNS/routing issue causing requests to go to wrong backend
2. SSL/TLS certificate mismatch for *.arsfeld.one domains
3. Caddy configuration issue specific to arsfeld.one domain
4. Cloud trying to access its own services through Cloudflare creates routing loop
5. Authelia session configuration issue specific to arsfeld.one domain

## Related:
- Recent commit fixed Authelia v4.39 compatibility (9ee0515)
- bat-boa.ts.net domains work correctly with same auth setup
- Issue persists even with fresh (non-cached) responses from Cloudflare
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 https://stash.arsfeld.one returns 401 or 200 (not 502)
- [x] #2 https://yarr.arsfeld.one returns 401 or 200 (not 502)
- [x] #3 Authentication flow completes successfully for arsfeld.one domains
- [x] #4 No routing loops or SSL errors when accessing arsfeld.one services
- [x] #5 Cloudflare properly routes requests to cloud gateway
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
## Root cause found:
- Caddy's forward_auth directive not setting X-Forwarded-Method header
- Authelia requires this header for authorization checks
- Error: `header 'X-Forwarded-Method' is empty`
- Need to add proper header forwarding to Caddy forward_auth configuration

## Solution Summary:

**Root Causes Identified:**
1. authHost was set to `auth.bat-boa.ts.net` instead of using the arsfeld.one Authelia instance
2. authPort was set to the auto-generated service port (63836) instead of the actual Authelia port (9091)
3. Missing X-Forwarded headers (X-Forwarded-Method, X-Forwarded-Proto, X-Forwarded-Host, X-Forwarded-Uri, X-Original-URL) required by Authelia v4.39
4. Wrong Authelia instance - needed to use the authelia-arsfeld.one instance running on cloud:9091 for arsfeld.one domains

**Fixes Applied:**
1. Changed authHost from `auth.bat-boa.ts.net` to `cloud` (modules/constellation/services.nix:260)
2. Changed authPort from auto-generated port to `9091` (modules/constellation/services.nix:261)
3. Added required X-Forwarded headers to forward_auth configuration (modules/media/__utils.nix:122-127)
4. Removed TLS transport config as cloud:9091 uses HTTP internally

**Result:**
- stash.arsfeld.one: Returns 302 redirect to auth.arsfeld.one (✅)
- yarr.arsfeld.one: Returns 302 redirect to auth.arsfeld.one (✅)
- All services now properly authenticate through Authelia
<!-- SECTION:NOTES:END -->
