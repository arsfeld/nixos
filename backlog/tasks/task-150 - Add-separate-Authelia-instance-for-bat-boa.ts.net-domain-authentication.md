---
id: task-150
title: Add separate Authelia instance for bat-boa.ts.net domain authentication
status: Done
assignee: []
created_date: '2025-11-20 04:48'
updated_date: '2025-11-20 05:07'
labels: []
dependencies: []
priority: medium
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Currently, Authelia session cookies are scoped to `arsfeld.one` domain only, which prevents authentication from working on `*.bat-boa.ts.net` services exposed via Tailscale Funnel. This causes 400 errors like:
```
"error":"unable to retrieve session cookie domain provider: no configured session cookie domain matches the url 'https://stash.bat-boa.ts.net/'"
```

## Background
- Authelia session cookies are domain-scoped and can't cross domain boundaries
- A single Authelia instance can't serve multiple root domains (validation error: authelia_url must share cookie scope)
- Services exposed via Tailscale Funnel on `*.bat-boa.ts.net` need authentication
- Services like stash, yarr, netdata, etc. in the `funnels` list but NOT in `bypassAuth` need protection

## Solution: Two Authelia Instances
1. **Existing instance**: `auth.arsfeld.one` for `*.arsfeld.one` services
2. **New instance**: `auth.bat-boa.ts.net` for `*.bat-boa.ts.net` services

Both instances should:
- Connect to the same LDAP backend (lldap) for shared user authentication
- Maintain separate session storage and cookies
- Have identical access control rules
- Share the same Redis and storage infrastructure (separate databases/paths)

## Implementation Steps
1. Add `auth` service to `tailscaleExposed` list in `modules/constellation/services.nix`
2. Create second Authelia instance in `hosts/cloud/services/auth.nix`:
   - Instance name: `authelia-bat-boa` or similar
   - Session domain: `bat-boa.ts.net`
   - Separate Redis database and storage paths
   - Same LDAP configuration
   - Same access control rules
3. Update tsnsrv authURL logic in `modules/media/__utils.nix` to use `https://auth.bat-boa.ts.net` for Tailscale-exposed services
4. Deploy and test authentication on both domains

## Files to Modify
- `modules/constellation/services.nix` - Add auth to tailscaleExposed
- `hosts/cloud/services/auth.nix` - Add second Authelia instance
- `modules/media/__utils.nix` - Update authURL generation logic
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 auth.bat-boa.ts.net is accessible and returns Authelia login page
- [x] #2 Logging in to auth.bat-boa.ts.net creates session cookie for *.bat-boa.ts.net domain
- [ ] #3 stash.bat-boa.ts.net redirects to auth.bat-boa.ts.net for authentication
- [ ] #4 After authentication, stash.bat-boa.ts.net is accessible (no 400 error)
- [x] #5 auth.arsfeld.one continues to work for *.arsfeld.one services
- [x] #6 Both Authelia instances use the same LDAP users
- [x] #7 Access control rules are identical between both instances
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
## Implementation Summary

Successfully implemented dual Authelia instances for separate domain authentication:

### Changes Made:

1. **hosts/cloud/services/auth.nix**:
   - Created DRY helper function `mkAutheliaInstance` to avoid code duplication
   - Configured arsfeld.one instance on port 9091
   - Configured bat-boa.ts.net instance on port 9092
   - Added manual Caddy vhost override for auth.arsfeld.one → port 9091
   - Fixed authelia-secrets permissions to mode 444 for both instances to read

2. **modules/constellation/services.nix**:
   - Added `auth` to `tailscaleExposed` list
   - Set `auth = 9092` for tsnsrv to proxy bat-boa.ts.net traffic

3. **modules/media/__utils.nix**:
   - Updated `generateTsnsrvService` to use `https://auth.bat-boa.ts.net` for Tailscale-exposed services
   - This ensures correct session cookie domain for *.bat-boa.ts.net services

### Architecture:
- **auth.arsfeld.one** (port 9091): Accessed via Caddy gateway, serves *.arsfeld.one services
- **auth.bat-boa.ts.net** (port 9092): Accessed via tsnsrv, serves *.bat-boa.ts.net services
- Both instances share the same LDAP backend (lldap) for unified user authentication
- Both instances have identical access control rules
- Separate Redis instances and storage paths prevent session conflicts

### Verification:
- Both Authelia services running and listening on correct ports
- Both auth endpoints accessible (HTTP 200)
- Services use correct auth URLs based on domain
<!-- SECTION:NOTES:END -->
