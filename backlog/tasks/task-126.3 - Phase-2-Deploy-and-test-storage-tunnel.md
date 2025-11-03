---
id: task-126.3
title: 'Phase 2: Deploy and test storage tunnel'
status: To Do
assignee: []
created_date: '2025-11-02 01:54'
updated_date: '2025-11-02 01:54'
labels:
  - cloudflare-tunnel
  - deployment
  - storage
dependencies:
  - task-126.2
parent_task_id: task-126
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Deploy cloudflared to storage host and verify storage services are accessible through the tunnel.

**Tasks**:
- Deploy cloudflared to storage
- Verify tunnel shows "Healthy" in Cloudflare dashboard
- Create test DNS record and verify connectivity
- Test media streaming and file uploads
- Test authentication forwarding to cloud Authelia

**Timeline**: Week 2, Days 11-13

**Reference**: Phase 2 in `docs/architecture/hybrid-dual-tunnel-plan.md`
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Storage tunnel shows 'Healthy' in Cloudflare dashboard
- [ ] #2 Test DNS record (test-jellyfin.arsfeld.one) reaches Jellyfin through tunnel
- [ ] #3 Video streaming works through tunnel (Jellyfin)
- [ ] #4 File upload works through tunnel (Nextcloud, <100MB)
- [ ] #5 Protected service authentication works (forward_auth to cloud Authelia)
- [ ] #6 Tailscale access still works
- [ ] #7 Git committed with message: feat(storage): deploy Cloudflare Tunnel for storage services
<!-- AC:END -->
