---
id: task-18
title: Analyze replacing modules/media/gateway.nix with cloudflared
status: Done
assignee: []
created_date: '2025-10-16 01:28'
updated_date: '2025-10-16 01:34'
labels:
  - infrastructure
  - analysis
  - networking
  - gateway
dependencies: []
priority: medium
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Conduct a comprehensive analysis of what it would take to replace the current media gateway implementation (which uses Caddy + tsnsrv + Authelia) with Cloudflare Tunnel (cloudflared).

Current gateway features to maintain:
- Centralized authentication via Authelia
- Automatic SSL certificate management
- Service discovery and routing (subdomain-based)
- Tailscale integration with optional public exposure
- CORS and security header management
- Error page handling
- Reverse proxy routing to services based on subdomain (service.domain.com)

The analysis should cover:
1. Feature parity assessment - which current features can/cannot be replicated with cloudflared
2. Authentication integration - how to integrate Authelia with Cloudflare Access or migrate to Cloudflare Access
3. SSL/TLS handling - how certificate management differs with Cloudflare
4. Tailscale integration - compatibility between Cloudflare Tunnels and Tailscale networking
5. Configuration migration - mapping current Caddy/tsnsrv configs to cloudflared
6. Service routing - how to maintain subdomain-based routing
7. NixOS integration - packaging and module structure for cloudflared
8. Migration path - step-by-step approach to migrate without service disruption
9. Trade-offs - pros/cons, features gained/lost, complexity changes
10. Cost implications - Cloudflare pricing for the use case
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Document current gateway.nix architecture and all features it provides
- [x] #2 Research cloudflared capabilities and NixOS integration options
- [x] #3 Create feature comparison matrix between current solution and cloudflared
- [x] #4 Identify blockers or missing features that would prevent migration
- [x] #5 Document authentication strategy (Authelia + Cloudflare or migrate to Cloudflare Access)
- [x] #6 Outline configuration approach for cloudflared in NixOS
- [x] #7 Create migration plan with rollback strategy
- [x] #8 Document trade-offs and provide recommendation
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
## Analysis Complete

Comprehensive analysis document created at `docs/cloudflared-migration-analysis.md`.

### Key Findings

1. **Current Architecture**: Caddy + tsnsrv + Authelia provides excellent integration for unified Tailscale + public access with centralized authentication

2. **Cloudflare Tunnel Capabilities**: Mature tunneling solution with good NixOS support, but introduces vendor lock-in and complexity

3. **Critical Blockers Identified**:
   - Loss of unified Tailscale + public access model
   - Authentication architecture must be compromised (lose Authelia features OR run dual auth)
   - Reduced declarative configuration capabilities

4. **Migration Complexity**: 6-7 weeks for full migration with significant risk

### Recommendation: DO NOT MIGRATE

**Reasoning**:
- No compelling business case - current solution works well
- Migration introduces more problems than it solves
- Vendor lock-in conflicts with self-hosting philosophy  
- Better investment: improve current stack documentation and monitoring

**When to revisit**:
- Tailscale Funnel discontinued or becomes expensive
- Team grows beyond 50 users
- Need true global CDN (service becomes commercial)
- Authelia development stalls

See full analysis document for detailed feature comparison, authentication strategies, migration plan with rollback procedures, and comprehensive trade-off analysis.
<!-- SECTION:NOTES:END -->
