---
id: task-118
title: Investigate MediaManager 500 error on OAuth callback from Authelia
status: Done
assignee: []
created_date: '2025-10-31 18:22'
updated_date: '2025-10-31 18:57'
labels:
  - bug
  - storage
  - media
  - authentication
  - oidc
dependencies: []
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
After successfully authenticating with Authelia, MediaManager returns a 500 Internal Server Error when processing the OAuth callback.

**Current Behavior:**
- User initiates OAuth login with MediaManager
- Authelia authentication succeeds
- Authelia redirects back to MediaManager callback endpoint
- MediaManager returns HTTP 500 error

**Error URL:**
```
https://mediamanager.arsfeld.one/api/v1/auth/oauth/callback?code=authelia_ac_...&iss=https%3A%2F%2Fauth.arsfeld.one&scope=openid+email+profile&state=...
```

**Expected Behavior:**
- MediaManager should exchange the authorization code for tokens
- Create or update user session
- Redirect user to the application

**Investigation Areas:**
1. Check MediaManager container logs for error details
2. Verify OIDC client secret is correctly configured
3. Check if MediaManager can reach Authelia's token endpoint
4. Review MediaManager's OIDC configuration in config.toml
5. Verify all required scopes are configured in Authelia client

**Related:**
- Parent task: task-114 (MediaManager database and OIDC setup)
- OIDC client ID: mediamanager
- Callback endpoint: /api/v1/auth/oauth/callback
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 OAuth callback completes successfully without 500 error
- [x] #2 User session is created after successful authentication
- [x] #3 User is redirected to MediaManager application after login
- [x] #4 Error logs show no exceptions during OAuth token exchange
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
## Root Cause Analysis

The MediaManager 500 error was caused by an **authentication method mismatch** between MediaManager and Authelia during the OAuth token exchange.

**Issue Details:**
- **MediaManager uses:** `client_secret_basic` (sends client_id/client_secret in Authorization header)
- **Authelia expected:** `client_secret_post` (expects credentials in POST request body)
- **Error from Authelia logs:**
  ```
  Access Request failed with error: Client authentication failed (e.g., unknown client, no client authentication included, or unsupported authentication method). The request was determined to be using 'token_endpoint_auth_method' method 'client_secret_basic', however the OAuth 2.0 client registration does not allow this method.
  ```

**Secondary Issue:**
- The redirect_uri in Authelia configuration was also incorrect:
  - **Configured:** `/web/auth/callback`
  - **Actual:** `/api/v1/auth/oauth/callback`

## Solution Implemented

Updated `secrets/authelia-secrets.age` for the MediaManager OIDC client:

1. Changed `token_endpoint_auth_method: 'client_secret_post'` → `'client_secret_basic'`
2. Fixed `redirect_uris` from `/web/auth/callback` to `/api/v1/auth/oauth/callback`

**Deployment:**
- Deployed to cloud host
- Restarted Authelia service to load new configuration
- Verified configuration loaded correctly

**Commit:** 0a13422 - fix(cloud): update MediaManager OIDC client auth method to client_secret_basic

## Additional Fix

After successful OAuth login, user was granted regular user access instead of admin. Fixed by updating admin_emails in MediaManager config from "admin@arsfeld.one" to "alex@rosenfeld.one".

**Commit:** 922fc22 - fix(storage): set alex@rosenfeld.one as MediaManager admin

## Admin Access Fix (Continued)

The `admin_emails` configuration in `config.toml` only applies to **new user creation**, not existing users. MediaManager stores admin status in the database `user.is_superuser` column.

**Database Fix:**
```sql
UPDATE "user" SET is_superuser = true WHERE email = 'alex@rosenfeld.one';
```

This grants superuser/admin privileges to the existing user account.
<!-- SECTION:NOTES:END -->
