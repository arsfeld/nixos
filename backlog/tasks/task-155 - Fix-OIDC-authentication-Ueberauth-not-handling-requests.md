---
id: task-155
title: Fix OIDC authentication - Ueberauth not handling requests
status: To Do
assignee: []
created_date: '2025-12-01 05:43'
labels:
  - bug
  - authentication
  - oidc
dependencies: []
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
The OIDC authentication flow is broken. When users try to login via OIDC (`/auth/oidc`), the error "Ueberauth didn't handle the request and no failure was set" occurs.

**Root Cause Analysis:**
- The Ueberauth OIDC strategy is not being registered/initialized at startup
- No OIDC-related logs appear during application startup, even with correct environment variables
- The runtime.exs OIDC configuration block doesn't seem to be executing

**Environment Variables (confirmed working):**
- `OIDC_ENABLED=true`
- `OIDC_DISCOVERY_DOCUMENT_URI=https://auth.arsfeld.one/.well-known/openid-configuration`
- `OIDC_CLIENT_ID=mydia`
- `OIDC_CLIENT_SECRET=<set>`
- `OIDC_REDIRECT_URI=https://mydia.arsfeld.one/auth/oidc/callback`
- `OIDC_SCOPES=openid profile email`

**Steps to Reproduce:**
1. Configure OIDC environment variables
2. Start mydia
3. Go to login page and click "Log in with OIDC"
4. Error: redirected back to login with flash "OIDC authentication configuration error"

**Expected Behavior:**
- Redirect to OIDC provider's authorization endpoint

**Actual Behavior:**
- `AuthController.request/2` receives request but Ueberauth hasn't set `ueberauth_auth` or `ueberauth_failure` in conn.assigns

**Related:** GitHub Issue #32

**Investigation Areas:**
- Check if `config :ueberauth, Ueberauth, providers: [oidc: {...}]` is being set in runtime.exs
- Verify oidcc library initialization with issuer
- Add startup logging to confirm OIDC configuration is loaded
<!-- SECTION:DESCRIPTION:END -->
