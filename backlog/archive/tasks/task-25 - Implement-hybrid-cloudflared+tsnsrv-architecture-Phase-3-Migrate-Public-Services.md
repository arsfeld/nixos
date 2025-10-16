---
id: task-25
title: >-
  Implement hybrid cloudflared+tsnsrv architecture - Phase 3: Migrate Public
  Services
status: To Do
assignee: []
created_date: '2025-10-16 03:17'
labels:
  - implementation
  - cloudflared
  - migration
dependencies:
  - task-22
priority: medium
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Migrate public-facing services (Funnel-enabled) to cloudflared in phases.

## Context

Phase 2 completed service classification. Now migrate ~45-50 public services to cloudflared to reduce CPU overhead.

## Migration Strategy

Migrate in batches:
1. **Batch 1**: Low-risk services (5-10 services)
2. **Batch 2**: Media services (jellyfin, plex, etc.)
3. **Batch 3**: Development tools (gitea, code, n8n)
4. **Batch 4**: Remaining services

Wait 24-48 hours between batches to monitor for issues.

## Tasks per Batch

1. Update service configuration to use cloudflared routing
2. Add cloudflared ingress rules
3. Update DNS records to point to Cloudflare
4. Remove Funnel configuration from services
5. Test access (public and from Tailnet)
6. Monitor CPU usage
7. Monitor for errors or performance issues
8. Document any issues and resolutions

## Success Criteria

- All public services migrated to cloudflared
- Services accessible and authenticated correctly
- Measured CPU reduction
- No major incidents or rollbacks needed
<!-- SECTION:DESCRIPTION:END -->
