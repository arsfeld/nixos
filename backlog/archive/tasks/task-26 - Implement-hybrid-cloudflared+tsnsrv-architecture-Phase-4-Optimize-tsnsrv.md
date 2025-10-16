---
id: task-26
title: 'Implement hybrid cloudflared+tsnsrv architecture - Phase 4: Optimize tsnsrv'
status: To Do
assignee: []
created_date: '2025-10-16 03:17'
labels:
  - implementation
  - tsnsrv
  - performance
  - optimization
dependencies:
  - task-22
priority: medium
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Reconfigure tsnsrv to only handle internal-only services, reducing instance count from 64 to ~10-15.

## Context

Phase 3 completed public service migration to cloudflared. Now optimize tsnsrv for remaining internal services.

## Tasks

1. Remove public services from tsnsrv configuration
2. Update `modules/media/gateway.nix` to only generate tsnsrv for internal services
3. Configure direct Caddy access for critical internal services
4. Remove unnecessary Funnel configurations
5. Deploy updated tsnsrv configuration
6. Verify internal services still accessible from Tailnet
7. Measure final CPU usage
8. Validate auth bypass still works for Tailnet users

## Expected Results

- tsnsrv instances reduced from 64 to ~10-15
- tsnsrv CPU usage: ~9-14% (down from 60.5%)
- cloudflared CPU usage: ~7-10%
- Total CPU usage: ~16-24%
- **Total savings: 36-44% CPU reduction**

## Validation

- All internal services accessible via Tailnet
- Auth bypass working correctly
- No performance degradation
- CPU metrics confirm expected savings
<!-- SECTION:DESCRIPTION:END -->
