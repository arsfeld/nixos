---
id: task-123
title: >-
  Plan architecture with dual Cloudflare Tunnels: storage for *.arsfeld.one,
  cloud for *.rosenfeld.one
status: Done
assignee: []
created_date: '2025-11-01 03:51'
updated_date: '2025-11-01 04:04'
labels:
  - architecture
  - planning
  - cloud
  - storage
  - cloudflare-tunnel
dependencies: []
priority: medium
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Create an alternative architecture plan to task-122 that uses Cloudflare Tunnels for BOTH hosts instead of decommissioning cloud.

**Goal**: Simplify architecture while keeping cloud services operational on a separate domain.

**Approach**:
- **Storage host**: Runs all media/storage services via Cloudflare Tunnel for *.arsfeld.one
- **Cloud host**: Keeps existing services (auth, mosquitto, owntracks, vault, yarr, thelounge, whoogle, metube) via Cloudflare Tunnel for *.rosenfeld.one
- **No service migration needed**: Cloud services stay on cloud
- **Eliminate split-horizon DNS**: Both hosts use Cloudflare Tunnels (outbound-only)
- **No duplicate Caddy**: Each host serves its own domain exclusively

**Key Differences from task-122**:
- task-122 recommended decommissioning cloud entirely (Option A with migration)
- This plan keeps cloud operational with its own domain
- Simpler migration: No service moves, just tunnel deployment
- Two domains, two tunnels, two hosts - but simplified routing

**Deliverable**:
A detailed architectural plan document covering:
- Dual Cloudflare Tunnel setup (one per host)
- Domain assignment (*.arsfeld.one → storage, *.rosenfeld.one → cloud)
- Service definitions (no migration, just domain changes)
- DNS configuration (Cloudflare for both domains)
- Elimination of split-horizon DNS
- Certificate management (ACME on both hosts)
- Implementation phases (simpler than full migration)
- Cost/benefit analysis vs task-122's recommendation
- Comparison of operational complexity
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Document analyzing dual-tunnel approach vs single-tunnel migration
- [x] #2 Cloudflare Tunnel configuration for storage host (*.arsfeld.one)
- [x] #3 Cloudflare Tunnel configuration for cloud host (*.rosenfeld.one)
- [x] #4 Service domain assignment strategy (which services on which domain)
- [x] #5 DNS configuration for both domains (eliminate split-horizon)
- [x] #6 Certificate management for dual domains
- [x] #7 Implementation phases (tunnel deployment, DNS cutover)
- [x] #8 Cost analysis (2 hosts + 2 tunnels vs 1 host + 1 tunnel)
- [x] #9 Operational complexity comparison
- [x] #10 Migration path if later wanting to consolidate to single host
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
# Implementation Plan

## Phase 0: Preparation (Week 1)
- [x] Create comprehensive architecture plan document (`docs/architecture/dual-tunnel-plan.md`)
- [ ] Set up Cloudflare Tunnels in dashboard (storage-arsfeld, cloud-rosenfeld)
- [ ] Add tunnel credentials to sops-nix
- [ ] Create NixOS modules for cloudflared on both hosts

## Phase 1: Storage Tunnel Deployment (Week 2)
- [ ] Deploy cloudflared to storage host
- [ ] Configure DNS records for *.arsfeld.one
- [ ] Test tunnel routing with temporary subdomain
- [ ] Validate service access and authentication

## Phase 2: Cloud Tunnel Deployment (Week 2)
- [ ] Deploy cloudflared to cloud host
- [ ] Configure DNS records for *.rosenfeld.one
- [ ] Test cloud services via tunnel
- [ ] Validate cross-host authentication (storage → cloud Authelia)

## Phase 3: DNS Cutover for *.rosenfeld.one (Week 3)
- [ ] Enable Cloudflare proxy for rosenfeld.one domain
- [ ] Monitor cloud services
- [ ] Validate no authentication errors from storage

## Phase 4: DNS Cutover for *.arsfeld.one (Week 3)
- [ ] Remove split-horizon DNS override from router
- [ ] Enable Cloudflare proxy for arsfeld.one domain
- [ ] Monitor all storage services
- [ ] Validate internal routing performance

## Phase 5: Cleanup and Documentation (Week 3)
- [ ] Simplify cloud Caddy config (remove storage proxying)
- [ ] Update documentation (CLAUDE.md, overview.md)
- [ ] Monitor for one week stability
- [ ] Mark task complete
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
# Architecture Plan Completed

Comprehensive dual Cloudflare Tunnel architecture plan created: **`docs/architecture/dual-tunnel-plan.md`**

## Key Highlights

### Architecture Summary
- **Storage host**: Serves `*.arsfeld.one` via Cloudflare Tunnel (~70 services)
- **Cloud host**: Serves `*.rosenfeld.one` via Cloudflare Tunnel (~8 services)
- **Eliminates**: Split-horizon DNS complexity
- **Preserves**: Service distribution (no migration needed)

### Comparison to Task-122

| Aspect | Task-122 (Single Tunnel) | Task-123 (Dual Tunnel) |
|--------|-------------------------|------------------------|
| Implementation | 6 weeks (service migration) | 2-3 weeks (tunnel deployment) |
| Risk | Medium (services moved) | Low (no migration) |
| Cost | $21-41/mo (save $6-11/mo) | $27-52/mo (no change) |
| Complexity | Lowest (1 host, 1 tunnel) | Medium (2 hosts, 2 tunnels) |
| Rollback | Moderate difficulty | Easy (DNS only) |

### Recommendation

**Short-term**: Implement dual tunnel (task-123) for:
- Faster deployment (2-3 weeks vs 6 weeks)
- Lower risk (no service migration)
- Proves Cloudflare Tunnel concept

**Long-term**: Consider migrating to single tunnel (task-122) after 3-6 months if:
- Cloud services are underutilized
- Cost savings justify migration effort
- Operational simplicity desired

### Implementation Timeline

**Total: 3 weeks**
- Week 1: Preparation (tunnel setup, credentials)
- Week 2: Deploy both tunnels and test
- Week 3: DNS cutover and monitoring

### Security Benefits

✅ No inbound firewall rules needed (outbound-only tunnels)
✅ Cloudflare WAF/DDoS protection
✅ Works behind CGNAT/dynamic IPs
✅ End-to-end TLS encryption preserved
✅ Easy rollback (DNS changes only)

## Service Distribution

**Storage (`*.arsfeld.one`)**: Jellyfin, Plex, Sonarr, Radarr, Overseerr, Nextcloud, Gitea, PhotoPrism, Home Assistant, and 60+ more media/storage services

**Cloud (`*.rosenfeld.one`)**: Authelia, LLDAP, Dex (auth stack), Mosquitto, OwnTracks, The Lounge, Vault, Yarr, Whoogle, Metube

## Next Actions

1. Review `docs/architecture/dual-tunnel-plan.md` in detail
2. Decide: Dual tunnel (task-123) or Single tunnel (task-122)?
3. If dual tunnel: Proceed to Phase 0 (Preparation)
4. If single tunnel: Close this task, implement task-122 instead

The plan is ready for implementation. All acceptance criteria have been documented.
<!-- SECTION:NOTES:END -->
