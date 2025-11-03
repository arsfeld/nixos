---
id: task-126.1
title: 'Phase 0: Prepare Cloudflare Tunnels and credentials'
status: To Do
assignee: []
created_date: '2025-11-02 01:53'
labels:
  - cloudflare-tunnel
  - preparation
  - cloud
  - storage
dependencies: []
parent_task_id: task-126
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Set up Cloudflare Tunnels in dashboard and prepare NixOS configurations.

**Tasks**:
- Create `cloud-arsfeld` and `storage-arsfeld` tunnels in Cloudflare dashboard
- Download and encrypt tunnel credentials
- Create NixOS modules for both hosts
- Test build configurations

**Timeline**: Week 1, Days 1-7

**Reference**: Phase 0 in `docs/architecture/hybrid-dual-tunnel-plan.md`
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Cloudflare Tunnels created in dashboard (cloud-arsfeld and storage-arsfeld)
- [ ] #2 Tunnel credentials downloaded and noted tunnel IDs
- [ ] #3 Credentials encrypted in sops (cloud) and ragenix (storage)
- [ ] #4 NixOS modules created: hosts/cloud/services/cloudflare-tunnel.nix
- [ ] #5 NixOS modules created: hosts/storage/services/cloudflare-tunnel.nix
- [ ] #6 Both configurations build successfully without errors
- [ ] #7 Git committed with message: feat(cloud,storage): add Cloudflare Tunnel configuration
<!-- AC:END -->
