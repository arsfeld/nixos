---
id: task-7
title: Complete caddy-tailscale migration testing and deployment
status: To Do
assignee: []
created_date: '2025-10-12 14:49'
labels:
  - infrastructure
  - deployment
dependencies:
  - task-6
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Once the Caddy package builds successfully, complete the phased migration from tsnsrv to Caddy-Tailscale and measure resource improvements.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Deploy test configuration with 3 services (speedtest, homepage, syncthing)
- [ ] #2 Verify test services accessible via Caddy-Tailscale
- [ ] #3 Migrate Phase 1: Internal services (autobrr, bazarr, sonarr, radarr, prowlarr)
- [ ] #4 Migrate Phase 2: Mixed services with conditional auth
- [ ] #5 Migrate Phase 3: Public services with own auth
- [ ] #6 Verify all services accessible and authentication working
- [ ] #7 Measure post-migration resource usage (CPU, RAM, process count)
- [ ] #8 Document resource savings achieved
- [ ] #9 Remove old tsnsrv configuration
- [ ] #10 Clean up test files and update documentation
<!-- AC:END -->
