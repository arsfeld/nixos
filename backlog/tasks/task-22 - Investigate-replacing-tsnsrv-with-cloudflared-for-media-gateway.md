---
id: task-22
title: Investigate replacing tsnsrv with cloudflared for media gateway
status: Done
assignee:
  - '@claude'
created_date: '2025-10-16 03:10'
updated_date: '2025-10-16 03:37'
labels:
  - investigation
  - architecture
  - tsnsrv
  - cloudflared
  - performance
dependencies:
  - task-20
priority: medium
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Evaluate cloudflared (Cloudflare Tunnel) as an alternative to tsnsrv for the media gateway to potentially reduce CPU overhead and simplify architecture.

## Context

Task-20 research revealed tsnsrv consumes 60.5% CPU for 57 services on storage, primarily due to Tailscale's netmon (network monitor) polling. Each service creates a separate tsnet.Server instance with its own netmon, and this overhead cannot be disabled or throttled.

Current architecture: tsnsrv provides Tailscale-based access to services with forward auth to Authelia. An existing analysis document (docs/cloudflared-migration-analysis.md) already explores this migration.

## Goals

1. **Performance comparison**: Determine if cloudflared has lower CPU overhead than tsnsrv for multi-service deployments
2. **Feature parity**: Verify cloudflared supports required features (forward auth, multi-service routing, SSL termination)
3. **Architecture impact**: Understand changes needed to modules/media/gateway.nix and service configurations
4. **Migration path**: Define incremental migration strategy if cloudflared is viable

## Key Questions to Answer

- Does cloudflared support forward authentication (Authelia integration)?
- Can cloudflared route to multiple backend services efficiently?
- What is the CPU overhead for 57 services compared to tsnsrv?
- How does cloudflared handle SSL/TLS termination?
- What are the networking implications (Tailscale Funnel vs Cloudflare Tunnel)?
- Does it support both internal (tailnet) and public access patterns?
- What is the operational complexity compared to current setup?

## Related Context

- Current setup uses modules/media/gateway.nix with tsnsrv + Caddy
- Task-18 analyzed replacing gateway.nix with cloudflared
- Existing analysis: docs/cloudflared-migration-analysis.md
- 57 services currently exposed through tsnsrv on storage host
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Review existing docs/cloudflared-migration-analysis.md document
- [x] #2 Research cloudflared forward auth capabilities and Authelia integration
- [x] #3 Determine CPU overhead characteristics for cloudflared with multiple services
- [x] #4 Compare feature matrix: tsnsrv vs cloudflared (auth, routing, SSL, monitoring)
- [x] #5 Evaluate network access patterns (internal tailnet vs public tunnel)
- [x] #6 Document migration complexity and architectural changes required
- [x] #7 Provide recommendation: migrate, stay with tsnsrv, or hybrid approach
- [x] #8 If recommended, create implementation tasks for migration
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
## Research Findings Summary

### Authelia Integration with cloudflared
**Confirmed**: cloudflared CAN work with Authelia for forward authentication.

**Key Resources Found**:
- GitHub tutorial: https://github.com/tamimology/cloudflare-authelia (step-by-step Docker setup)
- Comprehensive guide: https://florianmuller.com/setup-authelia-bare-metal-with-openid-and-cloudflare-tunnel-on-a-hardened-proxmox-lxc-ubuntu-22-04-lts-container
- LinuxServer.io: Zero Trust setup with Cloudflare + Authelia + SWAG

**Architecture Pattern**:
- cloudflared provides the tunnel/connectivity layer
- Authelia sits behind cloudflared for forward authentication
- Similar to current tsnsrv + Authelia pattern
- No need to migrate to Cloudflare Access

### CPU Overhead Comparison

**tsnsrv (Current)**:
- Creates **separate tsnet.Server instance per service** (57+ instances)
- Each instance has its own netmon that polls constantly
- **Result**: 60.5% CPU usage on storage host (from task-20)

**cloudflared**:
- **Single daemon handles unlimited services** via ingress rules
- Typical CPU usage: **5-10%** (can go to 15-25% with QUIC)
- Officially designed to run on Raspberry Pi with minimal resources
- Cloudflare blog states: "single configuration file is way better in terms of scale and memory footprint"

**Performance Impact**: Potential **50-55% CPU reduction** (60.5% → 5-10%)

### Key Architectural Difference

**Critical Finding**: The fundamental difference is:
- **tsnsrv**: N services = N separate daemons/instances = N × netmon overhead
- **cloudflared**: N services = 1 daemon with N ingress rules = O(1) overhead

This is exactly the problem tsnsrv has - it wasn't designed for multi-service deployments at scale.

### Current Service Count
- Cloud host: 13 services
- Storage host: 51 services  
- **Total: 64 services** (task mentions 57, may have been updated)

### Multi-Service Configuration Example
```nix
services.cloudflared.tunnels."<uuid>".ingress = {
  "jellyfin.arsfeld.one" = "http://localhost:8096";
  "radarr.arsfeld.one" = "http://localhost:7878";
  # ... 50+ more services, single daemon
};
```

## Network Access Patterns Analysis

### Current Architecture (tsnsrv + Caddy)
**Internal (Tailnet) Access**:
- Services accessible at `<service>.bat-boa.ts.net`
- Direct connection through Tailscale network
- Can bypass authentication for Tailnet users (`authBypassForTailnet = true`)
- Zero external dependencies
- Fast, low-latency access

**Public Access**:
- Selected services use Tailscale Funnel (56 services configured)
- Provides public HTTPS access through Tailscale's edge
- Integrated with Authelia for authentication
- Still benefits from Tailscale's network

**Unified Model**: Single configuration, single access pattern, seamless internal/external

### Cloudflared Architecture
**Public Access via Cloudflare Tunnel**:
- All traffic routes through Cloudflare's edge network
- Public HTTPS access at `<service>.arsfeld.one`
- SSL/TLS handled by Cloudflare
- Can integrate with Authelia for authentication
- DDoS protection included

**Internal (Tailnet) Access**:
- **Challenge**: Cloudflare Tunnel provides PUBLIC access, not private Tailnet access
- Two options:
  1. **Dual system**: Keep tsnsrv for Tailnet + add cloudflared for public
     - Maintains internal access patterns
     - Doubles complexity
     - Doesn't solve CPU problem (tsnsrv still runs 57 instances)
  2. **Public-only**: Force all access through Cloudflare
     - Loses Tailnet bypass feature
     - All traffic routes externally (even from within Tailnet)
     - Higher latency for internal users
     - Privacy concern (Cloudflare sees all traffic)

### Critical Difference
**tsnsrv**: Designed for Tailscale network (private first, optional public via Funnel)
**cloudflared**: Designed for public internet access (no private network integration)

### Access Pattern Comparison Table
| Scenario | tsnsrv (Current) | cloudflared Only | Hybrid (Both) |
|----------|------------------|------------------|---------------|
| **Internal Tailnet access** | ✅ Native, fast | ❌ Must go via Cloudflare | ✅ Via tsnsrv |
| **Public access** | ✅ Via Funnel | ✅ Via Cloudflare | ✅ Via Cloudflare |
| **Auth bypass for Tailnet** | ✅ Built-in | ❌ Not possible | ✅ Via tsnsrv |
| **Latency (internal users)** | Low (direct) | Higher (CF roundtrip) | Low (if using tsnsrv) |
| **CPU overhead** | ❌ 60.5% | ✅ 5-10% | ⚠️ Depends on split |
| **Configuration complexity** | Low (unified) | Low (single system) | High (two systems) |
| **Operational complexity** | Medium | Medium | High |
| **Privacy** | ✅ Private network | ⚠️ All via Cloudflare | ⚠️ Public via CF |

### Key Finding: Architectural Incompatibility
Cloudflared **cannot replace** tsnsrv's Tailnet access patterns without significant trade-offs. The CPU savings come at the cost of losing the unified private/public access model that is a core feature of the current architecture.

## Final Recommendation: HYBRID APPROACH

### Context: The CPU Problem Changes Everything
Task-18 concluded "DO NOT MIGRATE" because current solution worked fine. However, **task-20 discovered**: tsnsrv consumes **60.5% CPU**, making it unsustainable.

### The Dilemma
- **Migrate fully to cloudflared**: Save 50-55% CPU but lose unified Tailnet/public access
- **Keep tsnsrv**: Maintain excellent architecture but waste 60% CPU
- **Run both naively**: No CPU savings

### Recommended Solution: STRATEGIC HYBRID

Split services based on access patterns:

1. **Public-facing services** (Funnel-enabled) → **cloudflared**
   - Need public access anyway
   - Latency increase acceptable for external users
   - ~45-50 services
   
2. **Internal-only services** → **tsnsrv (reduced)**
   - Only accessed from Tailnet
   - Maintain fast, private access
   - ~10-15 services

3. **Critical internal** → **Direct Caddy**
   - Auth, lldap, internal APIs
   - No tsnsrv overhead
   - ~5 services

### Expected CPU Impact

**Current**: 64 tsnsrv instances = 60.5% CPU

**After hybrid**:
- cloudflared: 50 services = ~7-10% CPU
- tsnsrv: 10-15 services = ~9-14% CPU
- **Total: ~16-24% CPU**
- **Savings: 36-44% reduction**

### What We Keep
- ✅ Fast Tailnet access for internal services
- ✅ Auth bypass for Tailnet users
- ✅ No vendor lock-in for critical infrastructure
- ✅ Privacy for sensitive services
- ✅ Declarative NixOS configuration
- ✅ Authelia authentication

### What Changes
- ⚠️ Public services via Cloudflare (acceptable)
- ⚠️ Dual system complexity
- ⚠️ Two configuration patterns

### What We Gain
- ✅ 36-44% CPU reduction
- ✅ Better scalability for public services
- ✅ DDoS protection for public services
- ✅ Faster global access via Cloudflare edge

### Why Hybrid is Optimal

1. **Solves the problem**: 60.5% → 16-24% CPU
2. **Maintains core architecture**: Internal stays private and fast
3. **Pragmatic trade-offs**: CF edge reasonable for external users
4. **Incremental migration**: Phase over time
5. **Reversible**: Move services back if needed
6. **Best of both**: Performance + privacy where it matters

### Alternatives Rejected

**Option A**: Reduce services - Minimal savings (~10-15%)
**Option B**: Wait for tsnsrv fix - Architectural issue, unlikely
**Option C**: Fork tsnsrv - High maintenance burden
**Option D**: Full cloudflared - Too many compromises

## Final Recommendation Summary

**PRIMARY: HYBRID APPROACH**
- Migrate public services (Funnel) to cloudflared
- Keep internal services on reduced tsnsrv
- **36-44% CPU savings**
- Maintains unified access for internal services

**SECONDARY: If hybrid too complex**
- Audit and reduce service count
- Disable unnecessary Funnel configs
- Accept CPU cost

**NOT RECOMMENDED**:
- ❌ Full cloudflared migration
- ❌ Keep unchanged
- ❌ Fork tsnsrv

## REVISED RECOMMENDATION: Direct Caddy + Single Tailscale Funnel

### User Feedback
Hybrid approach rejected - too complex. Need solution that:
- Provides HTTPS
- Works from anywhere (public access)
- Fast locally (Tailnet)
- Simple architecture

### The Real Problem
We're creating **64 separate tsnsrv instances**, each creating its own Tailscale node. That's why CPU is 60.5%.

### The Simpler Solution: Eliminate tsnsrv Entirely

**Architecture**:
1. **One Caddy instance** handles all 64 services (already does this)
2. **One Tailscale Funnel** on the host (not per-service)
3. Caddy serves via Tailscale, Funnel enabled for public access
4. Authelia continues as forward auth to Caddy

**How it works**:
- Local/Tailnet users: Connect directly to Caddy via Tailscale (fast, <service>.bat-boa.ts.net)
- Public users: Connect via Tailscale Funnel to same Caddy (https://<service>.arsfeld.one)
- **One Tailscale connection** instead of 64
- No tsnsrv needed at all

**CPU Impact**:
- Current: 64 tsnsrv instances = 60.5% CPU
- New: 1 Caddy + 1 Tailscale connection = ~2-5% CPU
- **Savings: ~55% CPU reduction**

**What We Keep**:
- ✅ Fast Tailnet access (direct to Caddy)
- ✅ Public access (via Funnel)
- ✅ HTTPS everywhere
- ✅ Authelia authentication
- ✅ Unified configuration
- ✅ No vendor lock-in
- ✅ Simple architecture

**What Changes**:
- ❌ Remove tsnsrv completely
- ✅ Use Tailscale Serve/Funnel directly on Caddy
- ✅ Much simpler configuration

## Technical Implementation Details

### Discovery: Tailscale Funnel Limitations
Tailscale Funnel does NOT support wildcard subdomains for custom domains (only *.ts.net).

**However**, the solution is to use **Caddy with Tailscale plugin** (github.com/tailscale/caddy-tailscale).

### The Solution: Caddy-Tailscale Plugin

**How it works**:
1. Use `caddy-tailscale` plugin - Caddy runs AS a Tailscale node
2. Caddy joins Tailnet directly (no separate client needed)
3. Enable Funnel on Caddy's Tailscale node
4. Caddy handles all reverse proxy routing (already does this)
5. One Tailscale node instead of 64

**Access Patterns**:
- **Tailnet users**: Connect to Caddy at `<service>.bat-boa.ts.net` (fast, direct)
- **Public users**: Connect via Funnel to same Caddy (Funnel forwards to Caddy)
- **Custom domain** (arsfeld.one): Already handled by cloud host DNS/proxy

**Implementation**:
```nix
# Replace modules/media/gateway.nix line 147
# OLD: services.tsnsrv.services = tsnsrvConfigs;
# NEW: Use caddy-tailscale plugin

services.caddy = {
  enable = true;
  package = pkgs.caddy.withPlugins (plugins: with plugins; [
    caddy-tailscale
  ]);
  # Caddy config stays mostly the same
  # Add Tailscale listener to Caddy
};
```

**Benefits**:
- ✅ **1 Tailscale node** (Caddy itself) vs 64 (tsnsrv per service)
- ✅ Fast local access (direct Tailnet)
- ✅ Public access (via Funnel)
- ✅ HTTPS everywhere (Tailscale certs + ACME)
- ✅ Simple architecture
- ✅ No vendor lock-in
- ✅ ~55% CPU reduction
<!-- SECTION:NOTES:END -->
