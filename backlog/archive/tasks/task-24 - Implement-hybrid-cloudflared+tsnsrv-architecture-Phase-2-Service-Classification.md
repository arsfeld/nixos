---
id: task-24
title: >-
  Implement hybrid cloudflared+tsnsrv architecture - Phase 2: Service
  Classification
status: To Do
assignee: []
created_date: '2025-10-16 03:17'
labels:
  - implementation
  - cloudflared
  - planning
dependencies:
  - task-22
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Classify all 64 services into three categories for the hybrid architecture migration.

## Context

Phase 1 completed cloudflared setup. Now need to categorize services based on access patterns.

## Categories

1. **Public via cloudflared** (~45-50 services)
   - Currently have Funnel enabled
   - Need public internet access
   - Acceptable to route through Cloudflare edge

2. **Internal via tsnsrv** (~10-15 services)
   - Only accessed from Tailnet
   - No public access needed
   - Require fast, private access

3. **Direct via Caddy** (~5 services)
   - Critical internal infrastructure
   - Auth, lldap, internal APIs
   - No tsnsrv overhead needed

## Tasks

1. Review all services in `modules/constellation/services.nix`
2. Analyze actual usage patterns (internal vs external access)
3. Create service classification list
4. Update service configuration schema to support routing method
5. Document rationale for each category
6. Review classification with stakeholders

## Deliverables

- Service classification document
- Updated configuration schema
- Migration plan for each service group
<!-- SECTION:DESCRIPTION:END -->
