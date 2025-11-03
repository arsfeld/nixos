---
id: task-126.6
title: 'Phase 5: Simplify Caddy configurations'
status: To Do
assignee: []
created_date: '2025-11-02 01:54'
updated_date: '2025-11-02 01:54'
labels:
  - caddy
  - cleanup
  - cloud
  - storage
dependencies:
  - task-126.5
parent_task_id: task-126
priority: medium
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Clean up Caddy configurations now that proxying between hosts is eliminated.

**Tasks**:
- Verify Caddy configs auto-filtered by host
- Redeploy to ensure clean configs
- Verify each host only serves its own services
- Performance test and compare to baseline

**Timeline**: Week 3, Days 19-20

**Reference**: Phase 5 in `docs/architecture/hybrid-dual-tunnel-plan.md`
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Cloud Caddy config contains only cloud services (verified)
- [ ] #2 Storage Caddy config contains only storage services (verified)
- [ ] #3 No cloud → storage proxying in configs
- [ ] #4 All services still accessible after redeployment
- [ ] #5 Performance within acceptable range (latency measured)
- [ ] #6 Git committed: refactor: simplify Caddy configs for independent host operation
<!-- AC:END -->
