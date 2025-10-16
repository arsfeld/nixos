---
id: task-10
title: 'Prepare caddy-tailscale for deployment: OAuth setup and testing'
status: In Progress
assignee:
  - '@claude'
created_date: '2025-10-12 17:16'
updated_date: '2025-10-12 17:23'
labels:
  - infrastructure
  - deployment
dependencies: []
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Complete pre-deployment checklist: obtain Tailscale OAuth credentials, test authentication works, update outdated documentation, and clean up obsolete build tasks. Package is ready (task-8, task-9 done), now verify OAuth functionality before proceeding with migration.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Mark task-6 as Done (resolved by task-8 and task-9)
- [ ] #2 Archive task-4 and task-5 (obsolete - using official plugin, not fork)
- [ ] #3 Obtain OAuth client ID and secret from Tailscale admin console
- [ ] #4 Update tailscale-env.age with TS_API_CLIENT_ID and TS_API_CLIENT_SECRET
- [ ] #5 Deploy minimal test config and verify OAuth authentication works
- [ ] #6 Update docs/caddy-tailscale-migration.md to reflect official plugin usage
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Review and close task-6 (resolved by task-8 and task-9)
2. Review tasks 4 and 5 - determine if they should be archived
3. Check Tailscale admin console documentation for OAuth setup
4. Check current tailscale-env.age structure
5. Plan minimal test deployment configuration
6. Review and update migration documentation
<!-- SECTION:PLAN:END -->
