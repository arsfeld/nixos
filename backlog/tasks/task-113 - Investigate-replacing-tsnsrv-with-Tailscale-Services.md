---
id: task-113
title: Investigate replacing tsnsrv with Tailscale Services
status: Done
assignee: []
created_date: '2025-10-31 16:11'
updated_date: '2025-10-31 17:28'
labels:
  - investigation
  - tailscale
  - performance
  - tsnsrv
  - infrastructure
dependencies:
  - task-29
  - task-48
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
## Context

The current setup uses tsnsrv to expose 64 media services via individual Tailscale nodes (`*.bat-boa.ts.net`), consuming ~60.5% CPU. Previous attempts to optimize:
- **task-29**: Tried replacing with caddy-tailscale plugin (not deployed)
- **task-48**: Attempted caddy-tailscale but reverted due to high CPU and TLS issues

Tailscale now has a new official feature called **Tailscale Services** (beta) that may solve this problem more elegantly.

## What are Tailscale Services?

Tailscale Services (https://tailscale.com/kb/1552/tailscale-services) allow publishing internal resources as named services with stable DNS names, decoupled from specific devices:

**Key Features:**
- Layer 7 (HTTP/HTTPS) with path-based routing
- Layer 4 (TCP) forwarders for databases/standard services  
- Automatic TLS certificate provisioning for tailnet DNS names
- Built-in traffic steering and access control
- High-availability and horizontal scaling support
- Uses `tailscale serve` command for configuration

**Potential Benefits:**
- Single Tailscale connection instead of 64 separate nodes
- Official Tailscale solution (no third-party plugins)
- Native TLS certificate handling
- Expected major CPU reduction (60.5% → minimal)
- Simplified architecture

## Investigation Goals

1. **Feasibility**: Can Tailscale Services handle our 64-service media stack?
2. **Architecture**: How would service exposure work compared to tsnsrv?
3. **Authentication**: How does Authelia integration work with Tailscale Services?
4. **Migration**: What's required to migrate from tsnsrv?
5. **Limitations**: Are there any blockers (beta status, feature gaps, etc.)?

## Current Architecture

**tsnsrv approach:**
- 64 separate Tailscale nodes (one per service)
- Each service accessible at `<service>.bat-boa.ts.net`
- Significant CPU overhead from multiple tsnet instances
- Works but inefficient

## Questions to Answer

- Does Tailscale Services support reverse proxy scenarios (Caddy → backend services)?
- Can we maintain `<service>.bat-boa.ts.net` naming or do we need different DNS structure?
- How does TLS certificate provisioning work in practice?
- What's the performance impact compared to tsnsrv?
- Is the beta stable enough for production use?
- How does this interact with Tailscale Funnel for public access?
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Read Tailscale Services documentation thoroughly
- [x] #2 Understand how Layer 7 (HTTP) endpoints work with reverse proxies
- [x] #3 Determine if 64 services can be published via Tailscale Services
- [x] #4 Evaluate TLS certificate provisioning mechanism
- [x] #5 Assess authentication/authorization integration with Authelia
- [x] #6 Document migration path from tsnsrv to Tailscale Services
- [x] #7 Identify any blockers or limitations for our use case
- [x] #8 Make go/no-go recommendation with justification
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
## Investigation Findings (2025-10-31)

### What is Tailscale Services?

Tailscale Services is a beta feature that decouples internal resources from specific devices. Key characteristics:

**Architecture:**
- Services are defined in the Tailscale admin console with a MagicDNS name and TailVIP
- Backend hosts register using `tailscale serve` command
- Supports Layer 7 (HTTP/HTTPS), Layer 4 (TCP), and Layer 3 (IP) endpoints
- Can have multiple backend hosts for high availability and load balancing

**DNS Naming:**
- Services use format: `<service-name>.<tailnet>.ts.net` 
- Example: `media-server.bat-boa.ts.net` or custom service names
- Each service gets ONE MagicDNS name (no subdomain routing)

**TLS Certificates:**
- Automatic TLS certificate provisioning for tailnet DNS names
- Certificates managed by Tailscale

### Critical Limitation: No Virtual Host/Subdomain Routing

**The fundamental blocker:**
Tailscale Services does NOT support virtual host or subdomain routing. Each Service definition provides ONE DNS name.

**What this means for our use case:**
- Current: 64 services at `jellyfin.bat-boa.ts.net`, `plex.bat-boa.ts.net`, etc.
- With Tailscale Services: Would need 64 separate Service definitions
- Each would require its own `tailscale serve` process
- No CPU reduction compared to tsnsrv

**Why path-based routing doesn't work:**
- Would require all services at one domain with paths: `media.bat-boa.ts.net/jellyfin`, `/plex`, etc.
- Most web applications don't work properly when served from subpaths
- Not compatible with our current service architecture

**Alternatives that don't solve the problem:**
- **Tailscale Sidecars**: Still runs multiple Tailscale instances (one per service)
- **Multiple Services**: Same overhead as tsnsrv, just different implementation

### Architectural Comparison

**Current (tsnsrv):**
```
tsnsrv → 64 separate Tailscale nodes → Each at <service>.bat-boa.ts.net
CPU: 60.5%
DNS: Individual subdomains work perfectly
Auth: Authelia forward auth integration
Setup: Automated via NixOS module
```

**Tailscale Services (proposed):**
```
64 Service definitions (admin console) → 64 tailscale serve processes
CPU: Similar or worse (64 processes still needed)
DNS: Would require changing all names from .bat-boa.ts.net to .<tailnet>.ts.net
Auth: Tailscale identity headers (different from Authelia)
Setup: Manual service definitions + automated serve processes
```

### Authentication Integration Issues

**Current Authelia integration:**
- tsnsrv supports forward auth to Authelia
- Configurable bypass for tailnet users
- Seamless with existing auth infrastructure

**Tailscale Services authentication:**
- Provides Tailscale identity headers (Tailscale-User-Login, etc.)
- App capabilities with `--accept-app-caps` flag
- Different authentication model than Authelia
- Would require refactoring auth approach

### Service Limits

**Good news:**
- No numerical limit during beta period
- Can define thousands of services via API
- Supports automation at scale

**Bad news:**
- Each service still needs separate definition and backend process
- Doesn't reduce the "64 connections" problem

### Identified Blockers

**BLOCKER #1: No subdomain routing support**
- Tailscale Services provides ONE DNS name per service
- Cannot use virtual hosts or subdomains with a single Service
- Would require 64 separate Service definitions for 64 services
- This defeats the purpose of reducing overhead

**BLOCKER #2: No CPU reduction achievable**
- Would still need 64 separate `tailscale serve` processes
- Each process maintains a Tailscale connection
- Same (or potentially worse) CPU overhead as tsnsrv
- The "single connection" benefit doesn't apply to our use case

**BLOCKER #3: DNS naming migration**
- Current services use `<service>.bat-boa.ts.net`
- Tailscale Services would use `<service>.<tailnet>.ts.net` or custom names
- Would break existing bookmarks and configurations
- No clear benefit to justify the migration pain

**BLOCKER #4: Authentication architecture mismatch**
- tsnsrv integrates with Authelia forward auth
- Tailscale Services uses Tailscale identity headers
- Different authentication models
- Would require significant refactoring

**BLOCKER #5: Increased setup complexity**
- Requires manual service definitions in admin console (64 services)
- Or API automation to create/manage service definitions
- Current tsnsrv setup is fully automated via NixOS
- Adds operational overhead without clear benefit

**BLOCKER #6: Beta status concerns**
- Still in beta (though API stable)
- Future pricing/limits unknown
- May introduce breaking changes
- Not production-ready for critical infrastructure

### Alternative Solutions to Investigate

Since Tailscale Services doesn't solve the CPU problem, consider:

1. **Reduce number of exposed services**
   - Already attempted in task-49
   - Currently at 20 services in tailscaleExposed list
   - Further reduction would limit functionality

2. **Optimize tsnsrv itself**
   - Profile to find specific bottlenecks
   - May need upstream tsnsrv improvements
   - Could contribute patches if bottlenecks identified

3. **Hybrid approach**
   - Use tsnsrv for frequently accessed services
   - Use Tailscale Funnel + arsfeld.one for others
   - Already partially implemented

4. **Accept current overhead**
   - 60.5% CPU on storage host may be acceptable
   - Provides significant value (secure access to 64 services)
   - Alternative solutions may not be better

5. **Wait for Tailscale improvements**
   - Monitor for Tailscale Services enhancements
   - Wait for virtual host/subdomain routing support
   - Re-evaluate when feature matures

### Migration Path (if proceeding anyway)

If we were to migrate despite blockers, the path would be:

**Phase 1: Service Definitions (Manual)**
1. Create 64 Service definitions in Tailscale admin console
2. Assign MagicDNS names and TailVIPs
3. Configure access policies for each service

**Phase 2: Backend Implementation (Automated)**
1. Create NixOS module to generate `tailscale serve` systemd services
2. One service per exposed application
3. Configure auth headers and SSL settings
4. Handle state directory management

**Phase 3: Migration**
1. Run Tailscale Services alongside tsnsrv
2. Test each service individually
3. Update DNS/bookmarks to new names
4. Monitor CPU usage (likely no improvement)
5. Disable tsnsrv after validation

**Phase 4: Cleanup**
1. Remove tsnsrv configuration
2. Update documentation
3. Clean up old Tailscale nodes

**Estimated Effort:**
- Manual service definitions: 4-6 hours
- NixOS module development: 8-12 hours  
- Testing and migration: 8-12 hours
- Total: 20-30 hours

**Expected Outcome:**
- Same or worse CPU usage
- Different DNS names
- More complex management
- **NOT RECOMMENDED**

## Final Recommendation: NO-GO ❌

### Executive Summary

**Do NOT migrate to Tailscale Services.** The investigation reveals that Tailscale Services does not solve our CPU usage problem and introduces multiple significant downsides.

### Key Findings

**What we hoped for:**
- Single Tailscale connection instead of 64
- Major CPU reduction (60.5% → minimal)
- Simplified architecture
- Official Tailscale solution

**What we discovered:**
- Tailscale Services doesn't support virtual host/subdomain routing
- Would still require 64 separate connections/processes
- No CPU reduction achievable
- More complex setup with manual service definitions
- Breaks existing DNS names and configurations
- Authentication architecture incompatibility

### The Core Problem

Tailscale Services is designed for scenarios where:
- You have a small number of services
- Services can use path-based routing (e.g., `/api`, `/web`)
- You want high availability with multiple backends
- You need decoupled service definitions

Our use case requires:
- 64 independent services with separate DNS names
- Virtual host/subdomain routing (`jellyfin.bat-boa.ts.net`, `plex.bat-boa.ts.net`)
- Integration with existing Authelia authentication
- Minimal CPU overhead

These requirements are fundamentally incompatible with Tailscale Services' current design.

### Recommendation: Alternative Approaches

Instead of migrating to Tailscale Services, consider:

**Option 1: Accept Current State (RECOMMENDED)**
- 60.5% CPU overhead provides access to 64 services securely
- System is stable and working as designed
- Alternative solutions don't offer meaningful improvements
- Focus optimization efforts elsewhere

**Option 2: Profile and Optimize tsnsrv**
- Deep dive into tsnsrv CPU usage with pprof (attempted in task-17, task-19)
- Identify specific bottlenecks
- Contribute upstream improvements if possible
- May yield 10-20% improvements at best

**Option 3: Further Service Reduction**
- Review tailscaleExposed list (currently 20 services after task-49)
- Identify rarely-used services that can be arsfeld.one-only
- Potential to reduce to 10-15 critical services
- Trade-off: Less convenient access for some services

**Option 4: Wait and Monitor**
- Monitor Tailscale Services roadmap for subdomain routing support
- Re-evaluate when feature matures and exits beta
- Check GitHub issues #1196 and #3847 for progress
- Estimated timeline: 12-24 months (speculative)

### Decision Justification

The migration would require:
- 20-30 hours of implementation effort
- Breaking changes to all service DNS names
- Authentication architecture refactoring
- Ongoing manual service definition maintenance

And would result in:
- No CPU reduction (primary goal)
- Equal or worse performance
- Increased complexity
- Broken bookmarks and configurations

**Verdict:** The cost-benefit analysis clearly indicates this migration is not worthwhile.

### Lessons Learned

1. Tailscale Services is a promising feature, but not yet mature for our use case
2. Virtual host/subdomain routing is essential for multi-service deployments
3. The "official solution" isn't always better than community tools (tsnsrv)
4. Sometimes the current solution is the best available option

### Next Steps

1. Close this investigation task as complete
2. Document findings for future reference
3. Update task-16 (investigate high CPU load) with these findings
4. Consider creating a new task for Option 3 (service reduction) if desired
5. Set a reminder to re-evaluate Tailscale Services in Q3 2026

### Related Tasks

- **task-29**: Replace tsnsrv with Caddy Tailscale plugin (abandoned)
- **task-48**: Disable caddy-tailscale due to high CPU (reverted)
- **task-49**: Minimize tsnsrv exposed services (completed)
- **task-16**: Investigate high CPU load from tsnsrv (ongoing)

### References

- Tailscale Services Documentation: https://tailscale.com/kb/1552/tailscale-services
- Tailscale Serve Documentation: https://tailscale.com/kb/1242/tailscale-serve
- GitHub Issue #1196: Subdomain/wildcard domain resolution
- GitHub Issue #3847: Multiple services on single host using SNI
<!-- SECTION:NOTES:END -->
