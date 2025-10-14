---
id: task-12
title: Test Caddy Tailscale OAuth authentication end-to-end
status: To Do
assignee: []
created_date: '2025-10-12 16:40'
labels:
  - infrastructure
  - testing
dependencies:
  - task-11
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Verify that Caddy's Tailscale OAuth authentication works correctly with real credentials before proceeding with full migration. Test both internal (Tailnet) and external (Funnel) access scenarios.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Build test Caddy configuration with tailscale_auth directive
- [ ] #2 Configure test service with OAuth credentials from task-11
- [ ] #3 Deploy test config to storage host
- [ ] #4 Test internal access: verify Tailnet users can authenticate via OAuth
- [ ] #5 Test external access: verify Funnel users can authenticate via OAuth
- [ ] #6 Verify authentication provider logs show successful OAuth flow
- [ ] #7 Document OAuth behavior and any configuration requirements
<!-- AC:END -->
