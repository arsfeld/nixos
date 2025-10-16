---
id: task-27
title: >-
  Implement hybrid cloudflared+tsnsrv architecture - Phase 5: Documentation and
  Monitoring
status: To Do
assignee: []
created_date: '2025-10-16 03:17'
labels:
  - documentation
  - monitoring
  - operations
dependencies:
  - task-22
priority: low
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Document the hybrid architecture and set up ongoing monitoring to validate CPU improvements.

## Context

Phase 4 completed the hybrid migration. Now document the architecture and establish monitoring.

## Documentation Tasks

1. Update CLAUDE.md with hybrid architecture details
2. Document service routing patterns (cloudflared vs tsnsrv vs direct)
3. Create architecture diagram showing traffic flows
4. Document troubleshooting procedures
5. Update deployment documentation
6. Create runbook for adding new services

## Monitoring Tasks

1. Set up CPU usage alerts for tsnsrv and cloudflared
2. Create Grafana dashboard for gateway services
3. Monitor latency for public services (via Cloudflare)
4. Monitor latency for internal services (via Tailnet)
5. Track service availability metrics
6. Document baseline performance metrics

## Validation Period

Monitor for 2-4 weeks to ensure stability:
- No unexpected CPU spikes
- Service availability remains high
- Performance acceptable for users
- No authentication issues

## Deliverables

- Updated documentation
- Monitoring dashboards
- Performance baseline report
- Lessons learned document
<!-- SECTION:DESCRIPTION:END -->
