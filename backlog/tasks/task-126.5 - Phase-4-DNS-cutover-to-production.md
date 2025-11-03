---
id: task-126.5
title: 'Phase 4: DNS cutover to production'
status: To Do
assignee: []
created_date: '2025-11-02 01:54'
updated_date: '2025-11-02 01:54'
labels:
  - cloudflare-tunnel
  - dns
  - cutover
dependencies:
  - task-126.4
parent_task_id: task-126
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Enable Cloudflare proxy for all services, completing the cutover to tunnel-based routing.

**Tasks**:
- Enable proxy (orange cloud) for cloud services
- Enable proxy for storage services
- Test all services from multiple locations
- Monitor tunnel health and performance

**Timeline**: Week 3, Days 16-18

**Reference**: Phase 4 in `docs/architecture/hybrid-dual-tunnel-plan.md`
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 All cloud services proxied through Cloudflare (orange cloud enabled)
- [ ] #2 All storage services proxied through Cloudflare (orange cloud enabled)
- [ ] #3 All 83+ services accessible via *.arsfeld.one
- [ ] #4 Both tunnels showing 'Healthy' status
- [ ] #5 External clients route through Cloudflare correctly
- [ ] #6 Internal clients route directly to storage (low latency verified)
- [ ] #7 Authentication flows work (forward_auth to cloud)
- [ ] #8 Video streaming works (Jellyfin, Plex)
- [ ] #9 File uploads work (Nextcloud, Immich)
- [ ] #10 No 404 or 502 errors
- [ ] #11 Tested from multiple locations and devices
- [ ] #12 Git committed: feat: complete DNS cutover to hybrid dual-tunnel architecture
<!-- AC:END -->
