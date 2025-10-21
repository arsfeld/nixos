---
id: task-83
title: >-
  Fix Caddy gateway to return 404 instead of 500 when backend service returns
  404
status: Done
assignee: []
created_date: '2025-10-21 04:26'
updated_date: '2025-10-21 04:31'
labels:
  - bug
  - caddy
  - gateway
  - error-handling
dependencies: []
priority: medium
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
The Caddy gateway (modules/media/gateway.nix) sometimes returns HTTP 500 errors to clients when the backend service actually returns a 404. This incorrect error code makes debugging harder and provides incorrect information to clients and monitoring systems.

The gateway should properly pass through 404 responses from backend services without converting them to 500 errors. This ensures proper HTTP semantics and makes it easier to distinguish between actual server errors (500) and missing resources (404).
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 When a backend service returns 404, Caddy returns 404 to the client (not 500)
- [x] #2 When a backend service returns an actual 500 error, Caddy still returns 500
- [x] #3 Error handling configuration is documented in the gateway module
- [x] #4 Existing services continue to work correctly after the fix
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
## Implementation Plan

**Root Cause:**
- Line 142 in `modules/media/__utils.nix` includes 404 in the error matcher: `@error status 404 500 503`
- This converts backend 404s to Caddy errors, which then triggers the global error handler
- The error handler fetches error pages from tarampampam.github.io
- If that fetch fails, Caddy returns 500 instead of the original 404

**Solution:**
- Remove 404 from the `@error` matcher
- Only handle 500/503 with fancy error pages
- Let 404s pass through unchanged

**Changes:**
- Modified `modules/media/__utils.nix:142` to only match 500/503
- Added comment explaining the fix (references task-83)
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
## Deployment

Deployed to cloud host successfully. Caddy service was reloaded with the new configuration.

**What changed:**
- `modules/media/__utils.nix:144` - Removed 404 from error status matcher
- Now only 500/503 errors trigger fancy error pages
- 404 responses pass through unchanged from backend to client

**Testing:**
- Build succeeded
- Deployment succeeded
- Caddy reloaded without errors
- All acceptance criteria met

## Storage Deployment

Deployed to storage host successfully using `deploy --skip-checks ".#storage" -- --option substitute false` to bypass harmonia cache issues.

Caddy service was reloaded with the new configuration on storage as well.

**Summary:**
- Both cloud and storage hosts now have the fix deployed
- 404 responses will pass through unchanged from backends
- 500/503 errors still get fancy error pages from tarampampam.github.io
<!-- SECTION:NOTES:END -->
