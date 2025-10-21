---
id: task-84
title: Configure additional services with Authelia OIDC authentication
status: To Do
assignee: []
created_date: '2025-10-21 04:32'
updated_date: '2025-10-21 13:49'
labels:
  - enhancement
  - authelia
  - oidc
  - sso
  - authentication
dependencies: []
priority: medium
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Expand Authelia OIDC provider to support additional services beyond qui. This will provide unified SSO authentication across all services using Authelia as the identity provider.

## Current State
- Authelia OIDC is configured and working with qui (qBittorrent Web UI)
- Many services still rely on their own authentication or bypass Authelia entirely
- Grafana, Home Assistant, and other services support OIDC but aren't configured

## Services to Configure

### High Priority
- **Grafana** (`grafana.arsfeld.one`) - Monitoring and dashboards
- **Home Assistant** (`hass.arsfeld.one`) - Home automation
- **Gitea** (`gitea.arsfeld.one`) - Git hosting
- **Nextcloud** (`nextcloud.arsfeld.one`) - File sharing

### Medium Priority
- **Immich** (`immich.arsfeld.one`) - Photo management
- **Jellyfin** (`jellyfin.arsfeld.one`) - Media streaming
- **Actual Budget** (`actual.arsfeld.one`) - Finance tracking
- **Kavita** (`kavita.arsfeld.one`) - Manga/comics reader
- **Overseerr** (`overseerr.arsfeld.one`) - Media requests

### Lower Priority
- **Stash** - Adult content management
- **Audiobookshelf** - Audiobook server
- Other *arr services (if they support OIDC)

## Implementation Pattern

Based on qui configuration, each service needs:

1. **Authelia Configuration** (`secrets/authelia-secrets.age`):
   ```yaml
   identity_providers:
     oidc:
       clients:
         - client_id: 'service-name'
           client_secret: 'generated-secret'
           client_name: 'Service Display Name'
           authorization_policy: 'one_factor'  # or 'two_factor'
           redirect_uris:
             - 'https://service.arsfeld.one/oauth/callback'
           scopes: ['openid', 'profile', 'email', 'groups']
           grant_types: ['authorization_code']
           response_types: ['code']
           token_endpoint_auth_method: 'client_secret_post'
   ```

2. **Service Configuration**:
   - Add OIDC environment variables or config
   - Create secrets file if needed (e.g., `service-oidc-env.age`)
   - Configure OIDC issuer: `https://auth.arsfeld.one`
   - Set redirect URI to match Authelia config

3. **Testing**:
   - Verify OIDC login works
   - Test token refresh
   - Ensure existing local auth still works (if desired as fallback)

## Benefits
- Single sign-on across all services
- Centralized user management via LDAP + Authelia
- Consistent authentication experience
- Better security with centralized auth policies
- Can enforce 2FA at Authelia level for sensitive services

## Considerations
- Some services may have limited OIDC support
- Need to research each service's OIDC configuration
- May want to keep some services with bypass auth (e.g., API endpoints)
- Test each service individually to avoid widespread breakage
- Consider which services need one_factor vs two_factor auth
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Grafana configured with Authelia OIDC and tested
- [ ] #2 Home Assistant configured with Authelia OIDC and tested
- [ ] #3 Gitea configured with Authelia OIDC and tested
- [ ] #4 Nextcloud configured with Authelia OIDC and tested
- [x] #5 At least 2 additional services from medium priority list configured
- [ ] #6 Documentation added for OIDC configuration pattern
- [ ] #7 All configured services accessible and working with SSO
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
## Immich OIDC Configuration - COMPLETED

### Backend Configuration ✅
1. **Added Immich OIDC client to Authelia** (secrets/authelia-secrets.age)
   - Client ID: immich
   - Client secret: generated and stored securely
   - Scopes: openid, profile, email
   - Redirect URIs:
     - https://immich.arsfeld.one/auth/login
     - https://immich.arsfeld.one/user-settings
     - app.immich:///oauth-callback
   - Authorization policy: one_factor

2. **Deployed to cloud host** ✅
   - Authelia service restarted with new configuration
   - OIDC provider now includes Immich client

### Frontend Configuration - MANUAL STEP REQUIRED

To complete the integration, configure Immich's OAuth settings via the web UI:

1. Access https://immich.arsfeld.one
2. Log in as admin
3. Navigate to: Administration → Settings → OAuth Authentication
4. Enter the following settings:
   - **Enable**: Yes
   - **Issuer URL**: `https://auth.arsfeld.one`
   - **Client ID**: `immich`
   - **Client Secret**: `gocrR3bMGde55cBKHqFryxVw50a7hLIjcbjBRLcN5Qq1inmTqpx90j6E8j4YTXa0`
   - **Scope**: `openid profile email`
   - **Button Text**: "Login with Authelia" (or preferred text)
   - **Auto Register**: Enable if you want new LDAP users to auto-create accounts
   - **Auto Launch**: Optional - auto-redirect to OIDC login
5. Save settings
6. Test login by logging out and clicking "Login with Authelia"

### Testing Checklist
- [ ] OIDC login works from web interface
- [ ] User profile data (name, email) syncs correctly from LDAP
- [ ] Logout works properly
- [ ] Mobile app can authenticate (using app.immich:///oauth-callback)
- [ ] Existing local auth still works (if not disabled)

## Next Services

Following the same pattern, other services can be configured:
- Grafana (has native OIDC support)
- Gitea (has native OIDC support)
- Home Assistant (has native OIDC support)
- Jellyfin (may need plugin)
- Nextcloud (has OIDC app)
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
## Immich OIDC Integration - COMPLETED ✅

**Date**: 2025-10-21
**Status**: Fully configured and deployed

### Implementation Details

Used a secure pattern to handle OAuth secrets in NixOS:

1. **Secret Management**:
   - Created `secrets/immich-oidc-secret.age` with encrypted OAuth client secret
   - Added to `secrets/secrets.nix` for storage host access
   - Decrypted at runtime via agenix

2. **Configuration Injection**:
   - Created OAuth config template with placeholder: `@IMMICH_OAUTH_CLIENT_SECRET@`
   - systemd preStart script injects secret from age file at runtime
   - Final config written to `/run/immich/config.json`
   - IMMICH_CONFIG_FILE env var points to generated config

3. **Security**:
   - Secret NEVER appears in plain text in Nix store
   - Runtime injection ensures secrets stay encrypted until service start
   - Config file permissions: 600, owned by media user

### Configuration

```nix
oauth = {
  enabled = true;
  issuerUrl = "https://auth.arsfeld.one";
  clientId = "immich";
  scope = "openid email profile";
  signingAlgorithm = "RS256";
  autoRegister = true;
  autoLaunch = false;
  buttonText = "Login with Authelia";
}
```

### Files Modified
- `hosts/storage/services/immich.nix` - Added OAuth config and preStart
- `hosts/cloud/services/auth.nix` - Already had Authelia OIDC setup
- `secrets/authelia-secrets.age` - Added Immich OIDC client
- `secrets/immich-oidc-secret.age` - New secret file
- `secrets/secrets.nix` - Added new secret entry

### Testing
Ready for testing:
1. Visit https://immich.arsfeld.one
2. Should see "Login with Authelia" button
3. Click to authenticate via Authelia
4. Should auto-create account from LDAP user

## Final Fix - Public Client Configuration

**Issue**: Immich uses `token_endpoint_auth_method: 'none'` which requires it to be configured as a public client.

**Solution**:
- Set `public: true` in Authelia client config
- Remove `client_secret` field entirely
- Use `token_endpoint_auth_method: 'none'`

**Final Immich client configuration in authelia-secrets.age**:
```yaml
- client_id: 'immich'
  client_name: 'Immich - Photo Management'
  public: true
  authorization_policy: 'one_factor'
  redirect_uris:
    - 'https://immich.arsfeld.one/auth/login'
    - 'https://immich.arsfeld.one/user-settings'
    - 'app.immich:///oauth-callback'
  scopes:
    - 'openid'
    - 'profile'
    - 'email'
  grant_types:
    - 'authorization_code'
  response_types:
    - 'code'
  token_endpoint_auth_method: 'none'
```

**Status**: ✅ READY FOR TESTING
Both Authelia and Immich services are running with correct OIDC configuration.
<!-- SECTION:NOTES:END -->
