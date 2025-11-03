---
id: task-124
title: >-
  Plan hybrid dual-tunnel architecture: both hosts serve own services via
  Cloudflare, single domain
status: Done
assignee:
  - claude
created_date: '2025-11-01 13:12'
updated_date: '2025-11-01 17:37'
labels:
  - architecture
  - planning
  - cloud
  - storage
  - cloudflare-tunnel
  - hybrid
dependencies: []
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Create a hybrid architecture plan that combines the best aspects of task-122 and task-123:

**Goal**: Simplify architecture using Cloudflare Tunnels while maintaining current service distribution.

**Key Principles**:
- **Single domain** (`*.arsfeld.one`) - no need for two domains
- **Cloud host**: Runs its own services (auth, mqtt, utilities) via Cloudflare Tunnel
- **Storage host**: Runs its own services (media, files, apps) via Cloudflare Tunnel
- **Independent Caddy instances**: Each host's Caddy only serves its own services (no proxying between hosts)
- **Cloudflare intelligent routing**: Routes subdomains to correct tunnel based on service location

**What This Eliminates**:
- ❌ Cloud as redundant web proxy (task-122's main pain point)
- ❌ Split-horizon DNS complexity (router Blocky overrides)
- ❌ Duplicate Caddy configurations (each host now independent)
- ❌ Need for second domain (task-123's added complexity)
- ❌ Service migration requirements (task-122's 6-week timeline)

**Architecture**:
```
Internet → Cloudflare DNS (*.arsfeld.one)
    ├─ auth.arsfeld.one → Cloud Tunnel → Cloud Caddy → Authelia
    ├─ jellyfin.arsfeld.one → Storage Tunnel → Storage Caddy → Jellyfin
    ├─ vault.arsfeld.one → Cloud Tunnel → Cloud Caddy → Vault
    └─ plex.arsfeld.one → Storage Tunnel → Storage Caddy → Plex
```

**Comparison to Previous Plans**:
- **vs Task-122** (single tunnel): No service migration needed, both hosts stay operational
- **vs Task-123** (dual tunnel, dual domain): Only one domain needed, simpler DNS
- **vs Current**: Eliminates cloud as proxy, eliminates split-horizon DNS

**Benefits**:
- ✅ Fastest implementation (2-3 weeks, no migration)
- ✅ Lowest risk (no service moves, easy rollback)
- ✅ Simplest DNS (one domain, intelligent routing)
- ✅ Cloud no longer redundant proxy (serves own services only)
- ✅ Both hosts remain independent and operational
- ✅ Can still decommission cloud later if desired (migrate to task-122)

**Deliverable**:
A detailed architectural plan document covering:
- Dual Cloudflare Tunnel setup with single domain routing
- Service-to-tunnel mapping (which services route to which tunnel)
- Cloudflare Tunnel ingress configuration for subdomain routing
- Independent Caddy configurations (each host serves own services only)
- DNS configuration (single domain, multiple tunnels)
- Elimination of split-horizon DNS
- Certificate management (ACME on both hosts, single domain)
- Implementation phases (tunnel deployment, DNS cutover)
- Cost analysis (same infrastructure, improved architecture)
- Comparison to task-122 and task-123 approaches
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Document analyzing hybrid dual-tunnel approach vs task-122 (single tunnel) and task-123 (dual domain)
- [x] #2 Cloudflare Tunnel configuration for storage host with subdomain ingress rules
- [x] #3 Cloudflare Tunnel configuration for cloud host with subdomain ingress rules
- [x] #4 Service-to-tunnel mapping strategy (which *.arsfeld.one subdomains route to which tunnel)
- [x] #5 Cloudflare DNS configuration for single domain with multiple tunnel targets
- [x] #6 Independent Caddy configurations (remove cloud→storage proxying)
- [x] #7 Certificate management approach (ACME on both hosts for single domain)
- [x] #8 Implementation phases (tunnel deployment, Caddy simplification, DNS cutover)
- [x] #9 Cost analysis (no infrastructure changes, operational improvements only)
- [x] #10 Comparison of all three approaches (current, task-122, task-123, hybrid)
- [x] #11 Migration path if later wanting to consolidate to single host (task-122 compatibility)
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
## Implementation Plan

### Approach
Create a comprehensive hybrid dual-tunnel architecture document that combines the best aspects of task-122 (single tunnel, simple) and task-123 (dual tunnel, no migration).

### Key Innovation
- **Dual tunnels** (like task-123) but **single domain** (like task-122)
- Each host serves its own services via its own Cloudflare Tunnel
- Cloudflare intelligently routes subdomains to the correct tunnel
- No service migration needed (unlike task-122)
- Simpler than task-123 (only one domain)

### Document Sections
1. Executive summary with comparison to task-122 and task-123
2. Current architecture analysis (reuse from task-122, task-123)
3. Service-to-tunnel mapping (analyze services.nix and media.nix)
4. Cloudflare Tunnel configurations for both hosts
5. DNS configuration (single domain, intelligent routing)
6. Independent Caddy configurations (remove proxying)
7. Certificate management (ACME on both hosts)
8. Implementation phases (tunnel deployment, DNS cutover)
9. Cost analysis (no change vs current, compare to task-122/123)
10. Comprehensive comparison of all approaches
11. Future migration path to task-122 if desired

### Files to Analyze
- `modules/constellation/services.nix` - native service distribution
- `modules/constellation/media.nix` - container service distribution
- `modules/media/gateway.nix` - current gateway implementation
- Existing plans: `dual-tunnel-plan.md` and `simplification-plan.md`

### Deliverable
`docs/architecture/hybrid-dual-tunnel-plan.md` - comprehensive plan addressing all 11 acceptance criteria
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Created comprehensive hybrid dual-tunnel architecture plan at docs/architecture/hybrid-dual-tunnel-plan.md covering all 11 acceptance criteria

Document includes: Executive summary with comparison matrix, service-to-tunnel mapping for 83+ services, complete Cloudflare Tunnel NixOS configurations, DNS configuration strategy, independent Caddy setup, certificate management approach, detailed 8-phase implementation plan with validation checklists, cost analysis showing no infrastructure cost change, comprehensive comparison of all 4 approaches (current, task-122, task-123, task-124), migration path to task-122 for future consolidation, security considerations and rollback strategies

Key benefits: No service migration needed, 2-3 weeks implementation, single domain simplicity, eliminates split-horizon DNS, eliminates cloud as proxy, maintains flexibility for future consolidation

UPDATED PLAN based on user feedback: Maintains direct local access for performance, uses wildcard DNS + automated script for cloud services, simplifies split-horizon DNS to single wildcard rule instead of per-service rules

Key improvements: (1) Wildcard *.arsfeld.one → storage tunnel covers 70+ services automatically, (2) Automated NixOS script updates 13 cloud service CNAMEs via Cloudflare API, (3) Internal clients use simplified split-horizon DNS (*.arsfeld.one → storage IP) for direct fast access, (4) External clients use Cloudflare routing with intelligent subdomain mapping

Benefits over original plan: No manual DNS updates when adding storage services (wildcard), no bat-boa.ts.net performance issues (retired due to tsnet overhead), maintains fast local access for 95% of traffic, automated cloud service DNS management on deployment
<!-- SECTION:NOTES:END -->
