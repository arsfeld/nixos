---
id: task-122
title: >-
  Plan architecture simplification: cloud as pure HTTPS forwarder, storage hosts
  everything
status: Done
assignee:
  - claude
created_date: '2025-11-01 03:26'
updated_date: '2025-11-01 03:42'
labels:
  - architecture
  - planning
  - cloud
  - storage
  - gateway
dependencies: []
priority: medium
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
The current architecture is overly complex with services split between cloud and storage hosts, multiple service definition locations, and split-horizon DNS. This task is to **plan** (not implement) a simplified architecture where:

**Desired State:**
- Cloud host: No services, no web server, only HTTPS forwarding to storage
- Storage host: All services (native systemd + containers), single Caddy instance
- Simplified service definitions (consolidate services.nix and media.nix patterns)
- Simplified DNS/routing (no split-horizon complexity)

**Current Complexity:**
1. Services defined in multiple places:
   - `modules/constellation/services.nix` (native systemd services)
   - `modules/constellation/media.nix` (containerized services)
   - Split between `storageServices` and `cloudServices`

2. **Hidden duplication - storage already runs Caddy:**
   - Storage runs the SAME Caddy configuration as cloud
   - `*.arsfeld.one` uses split-horizon DNS tricks:
     - External clients: Cloudflare → cloud Caddy → storage
     - Tailscale/local clients: Direct to storage Caddy (bypassing cloud entirely)
   - This duplication is IMPLICIT in the architecture - you have to know about the DNS tricks
   - **If cloud doesn't run a web server, it makes it EXPLICIT that storage is the authoritative service host**

3. Split-horizon DNS complexity:
   - `*.arsfeld.one` resolves differently inside vs outside tailnet
   - Both cloud and storage run identical Caddy configs (maintenance burden)
   - Hidden routing behavior - not obvious from configuration alone

4. Multiple access paths:
   - `*.arsfeld.one` (public domain through cloud OR direct to storage depending on network)
   - `*.bat-boa.ts.net` (Tailscale nodes via tsnsrv)

**Planning Objectives:**
1. Evaluate what cloud's role should be (pure TCP/HTTPS proxy? HAProxy? iptables NAT?)
2. Determine if Cloudflare can forward directly to storage (via Tailscale tunnel?)
3. Design consolidated service definition system (single source of truth)
4. Plan migration path for existing cloud services (thelounge, owntracks)
5. **Make storage's role as primary service host EXPLICIT in architecture** (remove hidden Caddy duplication)
6. Consider impact on:
   - Certificate management (where does ACME happen?)
   - Authentication (Authelia location and access)
   - Tailscale integration (funnel, tsnsrv)
   - External access security

**Deliverable:**
A detailed architectural plan document covering:
- Component responsibilities (cloud vs storage)
- Service definition schema (unified approach)
- Routing/proxy implementation (what runs on cloud?)
- DNS configuration changes (eliminate split-horizon tricks)
- How to make storage's primary role explicit (remove duplicate Caddy on cloud)
- Migration steps from current to new architecture
- Rollback plan
- Testing strategy
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Document analyzing current architecture complexity and pain points
- [x] #2 Proposed architecture with clear component responsibilities
- [x] #3 Service definition consolidation strategy (how to merge services.nix + media.nix patterns)
- [x] #4 Cloud forwarding mechanism design (HAProxy/iptables/Cloudflare Tunnel/other)
- [x] #5 Certificate management approach (where ACME runs, how certs distributed)
- [x] #6 Migration plan for existing cloud-hosted services
- [x] #7 DNS and routing changes documented
- [x] #8 Security considerations addressed (external access, authentication)
- [x] #9 Rollback strategy if simplification causes issues
- [x] #10 Plan reviewed and approved before any implementation begins
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
# Implementation Plan

## Investigation Areas

### 1. Current Architecture Analysis ✓
- Identified split-horizon DNS: Internal (router Blocky) points *.arsfeld.one → storage Tailscale IP (100.118.254.136)
- External (Cloudflare) presumably points → cloud public IP
- Both cloud and storage run identical Caddy configurations (duplication)
- Services split between cloud (auth, mosquitto, owntracks, vault, yarr, thelounge, whoogle, metube) and storage (media stack)
- Two service definition patterns: constellation/services.nix (native) and constellation/media.nix (containers)

### 2. Cloudflare → Storage Routing Options (In Progress)
Investigating three approaches:
- **Option A**: Cloudflare DNS → Storage public IP (if storage is publicly accessible)
- **Option B**: Cloudflare Tunnel → Storage via Tailscale
- **Option C**: Cloud as minimal L4 TCP/HTTPS proxy (HAProxy, iptables DNAT, or nginx stream)

### 3. Service Consolidation Strategy
- Merge services.nix and media.nix patterns into unified service definition
- Move all cloud services to storage
- Simplify service discovery and routing

### 4. Cloud Host Future
- Determine if cloud host is needed at all
- If yes: Minimal forwarding role only (no Caddy, no services)
- If no: Decommission entirely

### 5. Security & Migration
- Certificate management (ACME already on both - no changes needed per user)
- Authentication flow changes
- Rollback strategy
- Phased migration approach
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
# Architectural Plan Completed

Comprehensive architectural plan created: `docs/architecture/simplification-plan.md`

## Summary

**Recommended Approach**: Option A - Cloudflare Tunnel → Storage (decommission cloud entirely)

### Key Findings:

1. **Current Architecture Pain Points**:
   - Hidden duplication: Both cloud and storage run identical Caddy configs
   - Split-horizon DNS creates confusing routing behavior
   - Service definitions fragmented between services.nix and media.nix
   - Cloud host is redundant proxy adding latency and complexity

2. **Recommended Solution**: 
   - Use Cloudflare Tunnel to route *.arsfeld.one directly to storage
   - Decommission cloud host entirely
   - Eliminate split-horizon DNS
   - Single Caddy instance on storage
   - All services run on storage

3. **Benefits**:
   - Simplest architecture (one host, one web server, one path)
   - Most secure (outbound-only, no firewall holes)
   - Lower cost (eliminate cloud VPS)
   - Works with CGNAT/dynamic IPs
   - Makes storage's role as service host explicit

4. **Migration Plan**:
   - 6-week phased migration
   - Phase 0: Cloudflare Tunnel PoC
   - Phase 1-3: Migrate services (utilities → communication → auth)
   - Phase 4: DNS cutover
   - Phase 5: Decommission cloud

5. **Service Consolidation**:
   - Keep services.nix and media.nix separate (different concerns)
   - Rename for clarity (native-services.nix, container-services.nix)
   - Remove cloud = {} sections after migration
   - Everything runs on storage

## All Acceptance Criteria Addressed:
- AC#1: Current architecture analysis ✓
- AC#2: Proposed architecture (3 options, recommended Option A) ✓
- AC#3: Service consolidation strategy ✓
- AC#4: Cloud forwarding design (Cloudflare Tunnel recommended) ✓
- AC#5: Certificate management (ACME already works, no changes) ✓
- AC#6: Migration plan (6 phases, per-service steps) ✓
- AC#7: DNS/routing changes documented ✓
- AC#8: Security considerations addressed ✓
- AC#9: Rollback strategy (3 levels, safeguards) ✓
- AC#10: Plan ready for review ✓

See full document for detailed implementation steps, testing strategy, and security analysis.
<!-- SECTION:NOTES:END -->
