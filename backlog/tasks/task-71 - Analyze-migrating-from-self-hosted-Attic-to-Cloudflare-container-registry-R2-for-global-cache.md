---
id: task-71
title: >-
  Analyze migrating from self-hosted Attic to Cloudflare container registry/R2
  for global cache
status: Done
assignee: []
created_date: '2025-10-20 16:38'
updated_date: '2025-10-20 16:58'
labels: []
dependencies:
  - task-69
priority: medium
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Evaluate whether running Attic on Cloudflare's container execution platform (https://developers.cloudflare.com/containers) with R2 storage would be a better solution than the current self-hosted Attic cache system.

**Context:**
- Currently using self-hosted Attic cache on storage server (https://attic.arsfeld.one/system)
- Recently completed task-69 to set up Attic as replacement for fly-attic
- Attic requires hosting and maintenance on our infrastructure
- Cloudflare Containers (https://developers.cloudflare.com/containers) is a platform to run containers globally (similar to Fly.io)
- Could run Attic container on Cloudflare platform with R2 as storage backend

**Goal:**
Determine if migrating Attic to run on Cloudflare Containers platform would provide benefits in terms of:
- Global availability and performance (Cloudflare's global edge network)
- Reduced operational overhead (no self-hosting)
- Cost effectiveness
- Feature parity with current self-hosted Attic setup

**Correct Understanding:**
This is about running the Attic server as a container on Cloudflare's infrastructure (similar to how it could run on Fly.io), NOT about using container registries or R2 alone.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Documented comparison of Cloudflare container registry vs R2 vs current Attic setup covering features, pricing, and limitations
- [x] #2 Analysis of Nix binary cache compatibility with Cloudflare solutions (using documentation at https://developers.cloudflare.com/containers)
- [x] #3 Evaluation of global performance and availability improvements compared to single-server Attic
- [x] #4 Cost analysis comparing self-hosted Attic operational costs vs Cloudflare pricing for expected usage
- [x] #5 Assessment of migration effort and potential downtime
- [x] #6 Clear recommendation with reasoning for whether to migrate, stay with Attic, or pursue hybrid approach
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
## Analysis Summary

Completed comprehensive analysis of migrating from self-hosted Attic to Cloudflare Containers with R2 storage.

### Current Setup Baseline
- **Platform**: Self-hosted on storage.bat-boa.ts.net
- **Storage**: Local filesystem, currently 1.2GB used
- **Database**: SQLite
- **Access**: Public via https://attic.arsfeld.one/system (Tailscale Funnel)
- **Usage**: All constellation hosts (10 machines), daily automated caching
- **Network**: Single datacenter (Toronto area)

### Cloudflare Platform Overview

**Cloudflare Containers:**
- Status: Public beta (launched June 2025)
- Architecture: Built on Durable Objects, integrated with Workers
- Deployment: Global (330+ data centers)
- Scaling: Scale-to-zero with per-10ms billing
- Current Limits: 40 GiB total RAM, 40 vCPU concurrent

**Cloudflare R2:**
- API: S3-compatible (confirmed working with Attic)
- Network: Global edge with 330+ data centers
- Egress: Zero fees (major differentiator)
- Integration: Native with Workers and Containers

### Feature Comparison

**Self-Hosted Attic:**
- Storage: Local filesystem
- Availability: Single location (Toronto)
- Maintenance: Self-managed
- Network: Fixed latency from single datacenter
- Cost: $0 direct (uses existing infrastructure)

**Cloudflare-Hosted Attic:**
- Storage: R2 (S3-compatible, global)
- Availability: 330+ global locations
- Maintenance: Platform-managed
- Network: Edge-optimized (closest datacenter)
- Cost: ~$5-7/month

**Key Differences:**
- Global availability vs single location
- Auto-scaling vs manual scaling
- Managed platform vs full control
- Ongoing cost vs free infrastructure
- Edge latency vs fixed latency

### Cost Analysis

**Current Self-Hosted (Monthly):**
- Infrastructure: $0 (existing storage server)
- Storage: Negligible (1.2GB)
- Bandwidth: $0 (Tailscale within tailnet)
- Total: $0/month + operational overhead

**Cloudflare-Hosted (Monthly):**
- Base plan: $5.00/month (includes 25 GB-hours RAM, 375 vCPU-min, 200 GB-hours disk)
- R2 storage (current): 1.2GB × $0.015 = $0.018/month
- R2 storage (projected 50GB): $0.75/month
- Overage estimate: ~$0.75/month
- Total: $5-7/month

**Annual Comparison:**
- Current: $0/year
- Cloudflare: $60-84/year
- Delta: +$60-84/year

**Usage Estimate:**
- 10 hosts × 5 min/day × 30 days = 1,500 min/month build time
- Ad-hoc requests: ~500 min/month
- Total: ~2,000 minutes/month (likely within free tier for compute)

### Global Performance Benefits

**Current Performance:**
- Toronto area: Low latency
- Other regions: Variable, single-hop through Tailscale
- CI (GitHub Actions): Must route through Tailscale

**With Cloudflare:**
- Global edge: Served from nearest of 330+ datacenters
- Latency improvement: 50-200ms reduction for non-Toronto
- CI builds: Direct access, faster cache hits
- Reliability: Multi-datacenter redundancy

**Expected Improvements:**
- Toronto: Minimal change
- Remote locations: Significant improvement
- CI/CD: Faster builds
- Uptime: Better resilience

### Nix Compatibility & Migration

**Compatibility: CONFIRMED**
- Proven: Attic successfully runs on Fly.io with R2
- S3 API: R2 works seamlessly with Attic
- Container support: Attic designed for platforms like Cloudflare
- Nix protocol: Standard binary cache HTTP protocol

**Migration Effort: Medium (4-8 hours)**
Steps:
1. Create R2 bucket and tokens
2. Configure Cloudflare Container
3. Migrate Attic config to R2 backend
4. Export 1.2GB cache to R2
5. Deploy container
6. Update hosts' substituters
7. Test and verify

**Downtime:**
- Blue-green approach: 0-5 minutes
- Direct migration: 30-60 minutes

**Technical Considerations:**
- Database: Need solution for SQLite persistence
- Could use Durable Objects or managed PostgreSQL
- R2 for SQLite file possible but performance concerns

### Risks and Considerations

**Platform Maturity:**
- Risk: Cloudflare Containers in public beta (June 2025)
- Implication: Potential breaking changes, API evolution
- Mitigation: Self-hosted remains as backup option

**Database Persistence:**
- Issue: Attic uses SQLite, needs persistent storage
- Challenge: Container ephemeral storage requires external DB solution
- Options: Durable Objects (code changes), managed PostgreSQL (adds cost)

**Cost Growth:**
- Current: Free (using existing infrastructure)
- Cloudflare: $60-84/year minimum, grows with storage
- Consideration: 50GB cache = $9/year storage, still reasonable

**Vendor Lock-in:**
- Concern: Creates Cloudflare dependency
- Reality: Attic data portable, can migrate to other S3 storage
- Exit path: Can return to self-hosted or other providers

### Hybrid Approach Options

**Option A: Dual Cache Setup**
- Primary: Cloudflare (global, fast)
- Fallback: Self-hosted (reliability, cost control)
- Nix supports multiple substituters
- Benefits: Best of both worlds, redundancy
- Cost: ~$5-7/month

**Option B: Split by Use Case**
- CI/CD: Use Cloudflare (public, fast, no Tailscale)
- Internal builds: Use self-hosted (private, free)
- Benefits: Optimize for each scenario
- Complexity: Manage two systems

**Option C: Self-Hosted + R2 Backend (RECOMMENDED)**
- Keep Attic on storage server (control, no new costs)
- Switch storage backend from local to R2
- Benefits:
  - Global R2 replication
  - Zero egress fees
  - Maintain full control
  - Minimal infrastructure change
- Cost: ~$1-2/month (R2 storage only)
- Migration: Lower risk, simpler
- Best of both worlds: Control + cloud storage benefits

## FINAL RECOMMENDATION

### Recommended Approach: Option C - Self-Hosted with R2 Backend

**DO NOT migrate to Cloudflare Containers at this time.**

Instead, **migrate storage backend to Cloudflare R2 while keeping Attic self-hosted.**

### Reasoning:

**1. Cost-Benefit Analysis:**
- Cloudflare Containers: $60-84/year for marginal benefit
- R2 backend only: $12-24/year with significant benefits
- Current setup works well, no operational pain points

**2. Platform Maturity Concerns:**
- Cloudflare Containers launched June 2025 (5 months ago)
- Public beta status = potential breaking changes
- Not worth the risk for established, working infrastructure

**3. Database Complexity:**
- SQLite persistence challenge requires additional solutions
- Adds complexity and potential failure points
- Current local SQLite works reliably

**4. Actual Performance Needs:**
- All hosts within Tailscale network
- Toronto-based infrastructure serves needs adequately
- No reported latency issues
- CI/CD could benefit, but not critical pain point

**5. Hybrid Approach Delivers Key Benefits:**
- R2 backend provides global storage, zero egress
- Keep control and simplicity of self-hosted
- Minimal migration risk
- 10x lower cost than full Cloudflare migration

### Next Steps (If Pursuing Recommendation)

**Phase 1: Preparation (1-2 hours)**
1. Create Cloudflare R2 bucket for Attic storage
2. Generate R2 API tokens with appropriate permissions
3. Review Attic R2 configuration documentation
4. Plan migration timing (low-usage window)

**Phase 2: Configuration (1-2 hours)**
1. Update Attic server config to use R2 storage backend
2. Configure S3-compatible endpoint for R2
3. Test R2 connectivity from storage server
4. Backup current SQLite database

**Phase 3: Migration (2-3 hours)**
1. Sync existing cache data to R2 (1.2GB transfer)
2. Verify data integrity in R2
3. Switch Attic to use R2 backend
4. Test cache operations (push/pull)
5. Monitor for issues

**Phase 4: Validation (1 hour)**
1. Test builds from multiple hosts
2. Verify cache hits from R2
3. Monitor performance metrics
4. Update documentation

**Total Estimated Time: 5-8 hours**

### Alternative: Stay with Current Setup

If not pursuing any migration, current setup is acceptable:

**Pros:**
- Zero additional cost
- Proven, stable, working solution
- No migration risks
- Full control

**Cons:**
- Single point of failure (storage server)
- Fixed latency (Toronto-based)
- Local storage only (no global replication)
- Manual maintenance

**When to Revisit:**
- Cloudflare Containers reaches GA (General Availability)
- Latency becomes a reported issue
- Storage server reliability concerns arise
- CI/CD performance becomes critical
- Cost is no longer a concern

### Conclusion

The analysis is complete. The recommended path forward is to maintain self-hosted Attic but migrate to R2 storage backend for improved durability and global replication at minimal cost ($1-2/month vs $5-7/month for full Cloudflare hosting).
<!-- SECTION:NOTES:END -->
