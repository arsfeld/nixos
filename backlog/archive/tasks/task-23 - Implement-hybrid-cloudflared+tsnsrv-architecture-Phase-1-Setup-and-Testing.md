---
id: task-23
title: 'Implement hybrid cloudflared+tsnsrv architecture - Phase 1: Setup and Testing'
status: To Do
assignee: []
created_date: '2025-10-16 03:17'
labels:
  - implementation
  - cloudflared
  - performance
  - infrastructure
dependencies:
  - task-22
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Implement Phase 1 of the hybrid cloudflared+tsnsrv migration to reduce CPU overhead from 60.5% to ~16-24%.

## Context

Task-22 investigation concluded that a strategic hybrid approach is optimal:
- Migrate public-facing services (Funnel-enabled) to cloudflared
- Keep internal-only services on reduced tsnsrv instance count
- Expected 36-44% CPU savings

## Phase 1 Goals

Set up cloudflared infrastructure and test with 2-3 non-critical public services before broader migration.

## Tasks

1. Create Cloudflare Tunnel and obtain credentials
2. Add cloudflared secrets to agenix
3. Create `modules/media/cloudflared.nix` module (similar to gateway.nix)
4. Add cloudflared configuration generation to `__utils.nix`
5. Test with 2-3 services (e.g., yarr, romm, speedtest)
6. Verify Authelia forward auth works with cloudflared
7. Monitor CPU usage and performance
8. Document any issues or configuration adjustments

## Success Criteria

- cloudflared running on storage host
- 2-3 test services accessible via cloudflared tunnel
- Authelia authentication working correctly
- DNS updated for test services
- CPU usage measured and documented
- No impact on other services
<!-- SECTION:DESCRIPTION:END -->
