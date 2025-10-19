---
id: task-69
title: 'Complete Attic cache setup: fix public URL and test workflows'
status: To Do
assignee: []
created_date: '2025-10-19 03:24'
labels:
  - infrastructure
  - nix
  - cache
dependencies: []
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Finish the self-hosted Attic binary cache setup by fixing remaining issues and testing the complete workflow. The core infrastructure is deployed and running, but needs final configuration and validation.

**Background:**
- Self-hosted atticd running on storage at http://storage.bat-boa.ts.net:8080
- Magic Nix Cache configured in GitHub Actions
- System cache created with admin token
- Substituters configured in common.nix

**Current Issues:**
1. Public URL (https://attic.arsfeld.one) returns 502 Bad Gateway
2. Local auto-push workflow not tested
3. CI caching not validated
4. SQLite permissions fix needs documentation
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Fix Caddy/tsnsrv routing to make https://attic.arsfeld.one accessible
- [ ] #2 Verify Attic server responds correctly at public URL
- [ ] #3 Test attic watch-store for automatic local build caching
- [ ] #4 Push a test build to the cache and verify it's accessible
- [ ] #5 Run a GitHub Actions build and verify Magic Nix Cache works
- [ ] #6 Document SQLite permissions workaround in cache.nix or CLAUDE.md
- [ ] #7 Update CLAUDE.md with final Attic setup instructions
- [ ] #8 Mark task-67 acceptance criteria #9 as complete
<!-- AC:END -->
