---
id: task-126.4
title: 'Phase 3: Deploy DNS automation and configure wildcard'
status: To Do
assignee: []
created_date: '2025-11-02 01:54'
updated_date: '2025-11-02 01:54'
labels:
  - cloudflare-tunnel
  - dns
  - automation
  - cloud
  - router
dependencies:
  - task-126.3
parent_task_id: task-126
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Deploy DNS automation script and configure wildcard DNS routing.

**Tasks**:
- Create DNS automation script on cloud host
- Configure Cloudflare API credentials
- Deploy and test DNS sync service
- Create wildcard DNS record for storage services
- Update router DNS to simplified wildcard

**Timeline**: Week 2, Days 14-15

**Reference**: Phase 3 in `docs/architecture/hybrid-dual-tunnel-plan.md`
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Cloudflare API token added to sops secrets
- [ ] #2 DNS automation script created: hosts/cloud/services/cloudflare-dns-sync.nix
- [ ] #3 DNS sync service deployed and running on cloud
- [ ] #4 13 cloud service CNAMEs created automatically via script
- [ ] #5 Wildcard CNAME created for storage services (*.arsfeld.one → storage tunnel)
- [ ] #6 Router DNS updated to simplified wildcard rule
- [ ] #7 DNS resolution correct (dig auth.arsfeld.one shows cloud tunnel, dig jellyfin.arsfeld.one shows storage tunnel)
- [ ] #8 Git committed: feat(cloud): add automated Cloudflare DNS management
- [ ] #9 Git committed: refactor(router): simplify split-horizon DNS to wildcard rule
<!-- AC:END -->
