---
id: task-126
title: Implement hybrid dual-tunnel Cloudflare architecture
status: To Do
assignee: []
created_date: '2025-11-02 01:52'
labels:
  - architecture
  - implementation
  - cloud
  - storage
  - cloudflare-tunnel
  - hybrid
dependencies: []
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Implement the hybrid dual-tunnel architecture planned in task-124, deploying Cloudflare Tunnels to both cloud and storage hosts with single domain routing.

**Architecture Overview**:
- **Dual Cloudflare Tunnels**: One on cloud, one on storage
- **Single domain**: All services use `*.arsfeld.one`
- **Intelligent routing**: Cloudflare routes subdomains to correct tunnel
- **Independent hosts**: Each serves only its own services
- **No migration**: Services stay on current hosts

**Key Benefits**:
- Eliminates cloud as redundant proxy
- Simplifies split-horizon DNS to one wildcard rule
- Automated DNS management for cloud services
- Maintains direct local access for performance
- Fast implementation (2-3 weeks)
- Low risk, easy rollback at any phase

**Reference**: `docs/architecture/hybrid-dual-tunnel-plan.md`

**Dependencies**: task-124 (planning - completed)
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Both Cloudflare Tunnels deployed and healthy (cloud-arsfeld and storage-arsfeld)
- [ ] #2 DNS configured with wildcard for storage services and explicit CNAMEs for cloud services
- [ ] #3 DNS automation script deployed and functioning on cloud host
- [ ] #4 All 83+ services accessible via *.arsfeld.one through correct tunnel
- [ ] #5 Split-horizon DNS simplified to single wildcard rule on router
- [ ] #6 Caddy configs simplified - each host only serves own services
- [ ] #7 Authentication flows working (storage services → cloud Authelia via Tailscale)
- [ ] #8 Internal clients have direct local access to storage (no Cloudflare hop)
- [ ] #9 External clients route through Cloudflare tunnels correctly
- [ ] #10 7 days stable operation with no critical issues
- [ ] #11 Documentation updated to reflect new architecture
- [ ] #12 Rollback procedures tested and documented
<!-- AC:END -->
