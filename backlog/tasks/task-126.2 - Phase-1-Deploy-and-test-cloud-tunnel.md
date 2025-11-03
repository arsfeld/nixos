---
id: task-126.2
title: 'Phase 1: Deploy and test cloud tunnel'
status: To Do
assignee: []
created_date: '2025-11-02 01:54'
updated_date: '2025-11-02 01:54'
labels:
  - cloudflare-tunnel
  - deployment
  - cloud
dependencies:
  - task-126.1
parent_task_id: task-126
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Deploy cloudflared to cloud host and verify cloud services are accessible through the tunnel.

**Tasks**:
- Deploy cloudflared to cloud
- Verify tunnel shows "Healthy" in Cloudflare dashboard
- Create test DNS record and verify connectivity
- Test authentication flows through tunnel

**Timeline**: Week 2, Days 8-10

**Reference**: Phase 1 in `docs/architecture/hybrid-dual-tunnel-plan.md`
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Cloud tunnel shows 'Healthy' in Cloudflare dashboard
- [ ] #2 Test DNS record (test-auth.arsfeld.one) reaches Authelia through tunnel
- [ ] #3 Authelia login works via tunnel
- [ ] #4 Tailscale access still works (auth.bat-boa.ts.net)
- [ ] #5 No errors in cloudflared logs
- [ ] #6 Git committed with message: feat(cloud): deploy Cloudflare Tunnel for cloud services
<!-- AC:END -->
