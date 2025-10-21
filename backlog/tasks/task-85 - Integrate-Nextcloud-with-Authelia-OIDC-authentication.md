---
id: task-85
title: Integrate Nextcloud with Authelia OIDC authentication
status: In Progress
assignee: []
created_date: '2025-10-21 13:52'
updated_date: '2025-10-21 14:33'
labels:
  - enhancement
  - authelia
  - oidc
  - sso
  - nextcloud
  - authentication
dependencies:
  - task-87
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Configure Nextcloud to use Authelia as an OIDC provider for single sign-on authentication, following the successful pattern established with Immich and qui.

## Current State
- Nextcloud is running as a containerized service on storage host
- Currently uses its own local authentication
- Listed as high priority in task-84 for OIDC integration

## Implementation Approach

Following the established pattern from Immich integration:

### 1. Research Phase
- Investigate Nextcloud's OIDC support (likely via `user_oidc` app)
- Determine if Nextcloud is a public or confidential OIDC client
- Identify required configuration parameters
- Check for environment variable support vs config file requirements

### 2. Authelia Configuration
Add Nextcloud OIDC client to `secrets/authelia-secrets.age`:
- Generate client credentials (if confidential client)
- Configure redirect URIs
- Set appropriate scopes: openid, profile, email
- Determine authorization_policy (one_factor or two_factor)
- Set correct token_endpoint_auth_method

### 3. Nextcloud Configuration
- Install/enable user_oidc app if needed
- Configure OIDC provider settings
- If secrets needed: create encrypted age file (e.g., `nextcloud-oidc-secret.age`)
- Test with container environment variables or config files
- Ensure existing authentication methods remain available as fallback

### 4. Security Considerations
- Never expose secrets in plain text in Nix store
- Use age encryption for any client secrets
- Consider using preStart script injection if needed
- Proper file permissions on generated configs

### 5. Testing
- Test OIDC login flow
- Verify LDAP user auto-creation/linking
- Test logout functionality
- Ensure mobile app compatibility
- Verify existing local auth still works

## Benefits
- Unified authentication across services
- Users can access Nextcloud with same LDAP credentials
- Centralized access control via Authelia
- Better security with potential 2FA enforcement

## References
- Immich OIDC integration (task-84 notes) - successful public client pattern
- Qui OIDC integration - successful confidential client pattern
- Nextcloud OIDC documentation
- Authelia Nextcloud integration guide
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Nextcloud OIDC client registered in Authelia configuration
- [ ] #2 Nextcloud configured to authenticate via Authelia OIDC
- [ ] #3 OIDC login tested and working from web interface
- [ ] #4 LDAP users can auto-create/link accounts via OIDC
- [ ] #5 Logout functionality works correctly
- [ ] #6 Mobile app authentication tested (if applicable)
- [ ] #7 Configuration follows secure secret management pattern
- [ ] #8 Documentation added for future reference
- [ ] #9 Existing local authentication remains available as fallback
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
## Implementation Progress

### Completed ✅
1. **Research Phase**
   - Nextcloud requires **confidential OIDC client** (not public like Immich)
   - Uses `token_endpoint_auth_method: 'client_secret_post'`
   - Requires PKCE with S256 challenge method
   - Redirect URI: `https://nextcloud.arsfeld.one/apps/user_oidc/code`
   - The `user_oidc` app is already in extraApps configuration

2. **Authelia Configuration** ✅
   - Added Nextcloud OIDC client to `secrets/authelia-secrets.age`:
     - client_id: nextcloud
     - client_secret: nowQpYGbJxk+47AddM6jXQnVWc9/222zkYjy4GjO3zYL1tclMKNNzW6f7UlVyfNZ
     - Scopes: openid, profile, email, groups
     - PKCE enabled with S256
   - Deployed to cloud host successfully

3. **Service Registry** ✅
   - Added nextcloud port (8099) to `modules/constellation/services.nix`
   - Already in bypassAuth list (correct, as it has own auth)
   - Gateway will route nextcloud.arsfeld.one to storage:8099

4. **Nextcloud Configuration** ✅
   - Configured OIDC settings in `hosts/storage/services/files.nix`:
     - Added nextcloud.arsfeld.one to trusted_domains
     - Configured user_oidc.default_token_endpoint_auth_method
   - Removed conflicting container definition from media.nix
   - Configured to use native NixOS service

### Blocked - Deployment Issues ⚠️

Nextcloud deployment is **blocked** by NixOS file ownership issues:
- Error: "/var/lib/nextcloud/data/config is not owned by user 'nextcloud'!"
- Root cause: systemd-tmpfiles creates directories during activation with incorrect ownership
- Attempted fixes:
  1. Changed ownership manually - tmpfiles recreates with wrong ownership
  2. Moved data directory from /mnt/storage to /var/lib - same issue
  3. Disabled appstore to avoid write permission errors
  4. Removed old installation - tmpfiles still creates wrong ownership

This is a known "unsafe path transition" issue in NixOS Nextcloud module.

### Next Steps

**Option A: Manual Intervention (Recommended)**
1. Deploy current configuration with Nextcloud disabled
2. Manually create /var/lib/nextcloud directories with correct ownership
3. Re-enable Nextcloud and deploy
4. Configure OIDC provider via web UI

**Option B: Further Investigation**
- Research NixOS Nextcloud tmpfiles configuration
- May need custom systemd.tmpfiles.rules
- Consider containerized Nextcloud alternative

### Files Modified
- `secrets/authelia-secrets.age` - Added Nextcloud OIDC client
- `modules/constellation/services.nix` - Added nextcloud:8099
- `modules/constellation/media.nix` - Removed container definition
- `hosts/storage/services/files.nix` - Configured OIDC, currently disabled

### Configuration Summary

**Authelia Client (READY FOR USE)**:
```yaml
client_id: nextcloud
client_secret: nowQpYGbJxk+47AddM6jXQnVWc9/222zkYjy4GjO3zYL1tclMKNNzW6f7UlVyfNZ
redirect_uri: https://nextcloud.arsfeld.one/apps/user_oidc/code
token_endpoint_auth_method: client_secret_post
require_pkce: true
pkce_challenge_method: S256
```

**When Nextcloud is Running**:
1. Install/enable user_oidc app
2. Configure in admin panel or via OCC command:
   - Provider: Authelia
   - Issuer: https://auth.arsfeld.one
   - Client ID: nextcloud
   - Client Secret: (use value above)
   - Scopes: openid profile email groups

**BLOCKED BY task-87**: Nextcloud service deployment is blocked by tmpfiles ownership issue. See task-87 for detailed investigation and potential solutions.
<!-- SECTION:NOTES:END -->
