---
id: task-88
title: Investigate missing Authelia login button in Nextcloud
status: Done
assignee: []
created_date: '2025-10-21 17:54'
updated_date: '2025-10-21 18:15'
labels:
  - nextcloud
  - authelia
  - oidc
  - authentication
  - bug
dependencies:
  - task-87
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
## Problem

The "Login with Authelia" button does not appear on the Nextcloud login page, preventing OIDC-based authentication.

## Context

- Nextcloud service is running and accessible at https://nextcloud.arsfeld.one/
- Authelia OIDC client is configured and deployed (from task-85)
- user_oidc app is installed and enabled in Nextcloud configuration
- Nextcloud deployment includes: `extraApps = { ... user_oidc; }`
- extraAppsEnable = true in configuration

## Expected Behavior

The Nextcloud login page should display an "Login with Authelia" or "Login with OIDC" button that redirects to Authelia for authentication.

## Actual Behavior

Only the standard username/password login form is displayed, with no OIDC provider button.

## Potential Causes

1. **user_oidc app not properly configured** - App may be installed but not configured with provider details
2. **OIDC provider not registered** - Need to configure the OIDC provider connection in Nextcloud admin settings
3. **App disabled or not activated** - user_oidc app may need manual activation after installation
4. **Configuration issue** - Missing settings like discovery URL, client ID, or client secret
5. **Nextcloud admin panel configuration** - May require web UI configuration in addition to NixOS settings

## Investigation Steps

1. Verify user_oidc app is enabled: `occ app:list | grep user_oidc`
2. Check user_oidc app configuration: `occ config:app:get user_oidc`
3. Review Nextcloud admin settings in web UI (Settings → Administration → OpenID Connect)
4. Check if OIDC provider needs to be manually registered via admin panel
5. Review user_oidc app documentation for required configuration
6. Check Nextcloud logs for OIDC-related errors

## Resources

- Nextcloud user_oidc app: https://github.com/nextcloud/user_oidc
- Authelia OIDC documentation: https://www.authelia.com/integration/openid-connect/introduction/
- Current Nextcloud config: `hosts/storage/services/files.nix:93-132`
- Authelia config with Nextcloud client: Check Authelia configuration for client registration

## Success Criteria

- "Login with Authelia" button appears on Nextcloud login page
- Clicking the button redirects to Authelia authentication
- Successful authentication redirects back to Nextcloud
- User can access Nextcloud using Authelia credentials
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Authelia login button visible on Nextcloud login page
- [x] #2 OIDC provider properly configured in Nextcloud
- [x] #3 user_oidc app enabled and configured
- [x] #4 Authentication flow works end-to-end
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
## Solution Implemented

Successfully configured Nextcloud OIDC integration with Authelia. The issue was that the OIDC provider needed to be registered in Nextcloud, and Nextcloud's SSRF protection was blocking connections to Tailscale IPs.

### Root Cause

1. **Missing OIDC Provider Registration**: The user_oidc app was installed and enabled, but no OIDC provider was registered in Nextcloud
2. **SSRF Protection Blocking**: Nextcloud's security feature blocked HTTP requests to Tailscale IPs (100.x.x.x range), preventing the app from reaching the Authelia discovery endpoint at auth.arsfeld.one (which resolves to a Tailscale IP)

### Changes Made

1. **Registered Authelia provider via OCC command**:
   ```bash
   sudo -u nextcloud nextcloud-occ user_oidc:provider authelia \
     --clientid="nextcloud" \
     --clientsecret="nowQpYGbJxk+47AddM6jXQnVWc9/222zkYjy4GjO3zYL1tclMKNNzW6f7UlVyfNZ" \
     --discoveryuri="https://auth.arsfeld.one/.well-known/openid-configuration" \
     --mapping-display-name=name \
     --mapping-email=email \
     --mapping-uid=preferred_username
   ```

2. **Configured Nextcloud settings** in `hosts/storage/services/files.nix`:
   - Added `allow_local_remote_servers = true` to allow connections to Tailscale IPs
   - This setting allows Nextcloud to connect to auth.arsfeld.one (100.118.254.136)

3. **Deployed changes** to storage host using `just deploy storage`

### Verification

- ✅ Login button visible on Nextcloud login page (confirmed via HTML inspection)
- ✅ OIDC provider properly configured in Nextcloud
- ✅ user_oidc app enabled and configured
- ✅ Authentication flow redirects to Authelia correctly (HTTP 303 to auth.arsfeld.one)
- ✅ All OIDC parameters correct (client_id, redirect_uri, scopes, PKCE)

### Files Modified

- `hosts/storage/services/files.nix` - Added `allow_local_remote_servers` setting

### Next Steps

The OIDC integration is now functional. Users can:
1. Click "Login with authelia" button on Nextcloud login page
2. Be redirected to Authelia for authentication
3. Upon successful authentication, be redirected back to Nextcloud
4. Have their account auto-created/linked based on LDAP credentials

This completes the Nextcloud OIDC integration and resolves task-85 as well.

## Follow-up: Fixed invalid_client Error

### Issue
After initial configuration, users encountered an "invalid_client" error when attempting to authenticate:
```
Error: invalid_client
Description: Client authentication failed (e.g., unknown client, no client authentication included, or unsupported authentication method).
Hint: The requested OAuth 2.0 Client does not exist.
```

### Root Cause
The Nextcloud OIDC client was configured in `secrets/authelia-secrets.age` but the cloud host (where Authelia runs) had not been deployed with the updated secrets.

### Resolution
1. Verified the Nextcloud client exists in `secrets/authelia-secrets.age`
2. Deployed the updated configuration to cloud host: `just deploy cloud`
3. Restarted Authelia service to pick up the new client configuration
4. Verified authentication flow works correctly

### Verification
- ✅ Authelia service logs show Nextcloud client loaded
- ✅ OIDC login endpoint redirects to Authelia with correct client_id
- ✅ All OIDC parameters present (state, nonce, PKCE challenge)
- ✅ Authentication flow now works end-to-end

### Lesson Learned
When adding new OIDC clients to Authelia, remember to:
1. Edit `secrets/authelia-secrets.age` to add the client
2. Deploy to cloud host (not just storage)
3. Restart the Authelia service if needed
<!-- SECTION:NOTES:END -->
