---
id: task-158
title: Investigate and fix Mydia OIDC authentication - RuntimeUeberauth plug
status: In Progress
assignee: []
created_date: '2025-12-01 21:55'
labels:
  - bug
  - authentication
  - oidc
  - mydia
dependencies: []
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
## Problem

OIDC authentication in Mydia fails with error: "Ueberauth didn't handle the request and no failure was set"

## Root Causes Identified

1. **Missing `redirect_uri`**: The Ueberauth OIDC config was missing the required `redirect_uri` option (fixed in runtime.exs)

2. **Compile-time vs runtime config**: The `plug Ueberauth` in AuthController reads config at compile time, but OIDC providers are configured via environment variables in runtime.exs which runs after compilation

## Fixes Applied (in ../mydia)

1. **config/runtime.exs**: Added `oidc_redirect_uri` reading and passing to Ueberauth config

2. **lib/mydia_web/plugs/runtime_ueberauth.ex**: Created new wrapper plug that calls `Ueberauth.init([])` at runtime instead of using cached compile-time routes

3. **lib/mydia_web/controllers/auth_controller.ex**: Changed `plug Ueberauth` to `plug MydiaWeb.Plugs.RuntimeUeberauth`

## Next Steps

- [ ] Build new Docker image with fixes
- [ ] Deploy to storage host
- [ ] Test OIDC login flow
- [ ] Verify redirect to Authelia works
- [ ] Verify callback handling works
- [ ] If still failing, add debug logging to RuntimeUeberauth plug
- [ ] Submit PR to getmydia/mydia repo
<!-- SECTION:DESCRIPTION:END -->
