---
id: task-156
title: Investigate and fix Immich OIDC authentication with Authelia
status: Done
assignee: []
created_date: '2025-12-01 20:16'
updated_date: '2025-12-01 20:24'
labels:
  - bug
  - oidc
  - immich
  - authelia
dependencies: []
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Immich OIDC login returns error 500. The issue is that Authelia rejects Immich's `client_secret_post` token endpoint authentication method.

## Current State
- Immich 2.3.1 running on storage host
- Authelia 4.39.12 running on cloud host (two instances: arsfeld.one on 9091, bat-boa.ts.net on 63836)
- Updated authelia-secrets.age to configure Immich client with `token_endpoint_auth_method: 'client_secret_post'`
- Restarted both Authelia instances and cleared their databases
- Error persists: "The request was determined to be using 'token_endpoint_auth_method' method 'client_secret_post', however the OAuth 2.0 client registration does not allow this method."

## Investigation Done
1. Verified Immich OAuth config at `/run/immich/config.json` has correct clientId and clientSecret
2. Verified authelia-secrets.age has `token_endpoint_auth_method: 'client_secret_post'` for immich client
3. Restarted both Authelia instances (arsfeld.one and bat-boa.ts.net)
4. Cleared Authelia SQLite databases to remove cached state
5. Confirmed storage's Caddy proxies auth.arsfeld.one to cloud:63836 (bat-boa.ts.net instance)

## Next Steps to Investigate
1. Check if Authelia is actually reading the `token_endpoint_auth_method` config properly
2. Verify the YAML indentation in authelia-secrets.age is correct
3. Try using `client_secret_basic` instead of `client_secret_post` if Immich supports it
4. Check Authelia source code or docs for how token_endpoint_auth_method should be configured
5. Consider if there's a mismatch between what config Authelia loads vs what it uses at runtime
<!-- SECTION:DESCRIPTION:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
## Update 2025-12-01 15:16

The error changed from `invalid_client` to `invalid_grant` after restarting both Authelia instances. This indicates:

1. **FIXED**: The `client_secret_post` authentication method is now accepted
2. **NEW ISSUE**: The authorization code from before the restart is invalid

User needs to clear cookies and try a fresh login flow. If that works, the issue is resolved.

## Fix Applied 2025-12-01

**Root Cause:** Storage's Caddy was proxying `auth.arsfeld.one` to `cloud:63836` (bat-boa.ts.net Authelia instance), but the authorization codes were issued by the arsfeld.one Authelia instance on port 9091.

**Solution:** Updated `modules/constellation/services.nix` to set explicit port for auth service:
```nix
auth = 9091; # Explicit port for arsfeld.one Authelia (bat-boa.ts.net uses 63836)
```

This ensures storage's Caddy proxies auth.arsfeld.one to cloud:9091 (correct instance).
<!-- SECTION:NOTES:END -->
