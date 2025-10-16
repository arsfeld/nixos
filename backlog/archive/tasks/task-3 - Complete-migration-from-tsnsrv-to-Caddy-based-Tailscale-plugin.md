---
id: task-3
title: Complete migration from tsnsrv to Caddy-based Tailscale plugin
status: In Progress
assignee:
  - '@claude'
created_date: '2025-10-12 14:17'
updated_date: '2025-10-12 14:49'
labels:
  - infrastructure
  - optimization
  - tailscale
dependencies: []
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Finish migrating from 57 individual tsnsrv processes to a single Caddy instance with Tailscale OAuth integration to reduce resource usage by ~85% (from 40% CPU/2.4GB RAM to 5-10% CPU/200-300MB RAM). The infrastructure and module are ready; need to execute the migration phases.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Create and encrypt the tailscale-env.age secret with TS_AUTHKEY
- [ ] #2 Deploy and test with minimal services (speedtest, homepage, syncthing)
- [x] #3 Measure and document baseline resource usage (tsnsrv: processes, CPU, RAM)
- [ ] #4 Migrate Phase 1: Internal services (autobrr, bazarr, sonarr, radarr, prowlarr)
- [ ] #5 Migrate Phase 2: Mixed services with conditional auth (jellyfin, immich, filebrowser, nextcloud)
- [ ] #6 Migrate Phase 3: Public services with own auth (gitea, grafana, home-assistant, plex)
- [ ] #7 Verify all services accessible and authentication working correctly
- [ ] #8 Measure and document post-migration resource usage (Caddy: process, CPU, RAM)
- [ ] #9 Remove old tsnsrv configuration from hosts/storage/services/misc.nix
- [ ] #10 Clean up test files (caddy-tailscale-test.nix) and update documentation
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Understand current state: Review Caddy module, storage host config, and existing tsnsrv setup
2. Check if tailscale-env.age secret exists or needs creation
3. Identify all services currently using tsnsrv in hosts/storage/
4. Create baseline measurement plan for resource usage
5. Deploy test configuration with minimal services (speedtest, homepage, syncthing)
6. If tests pass, migrate services in three phases (internal, mixed, public)
7. Verify each phase before proceeding to next
8. Document resource usage improvements
9. Remove old tsnsrv configuration and clean up test files
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
## Baseline Resource Usage (tsnsrv)
- **Processes**: 58 tsnsrv processes
- **CPU Usage**: 40.4% total
- **Memory Usage**: 11.6% (≈3,699 MB out of 31,889 MB total RAM)
- **Memory per process**: ~64 MB average

## Blocker Encountered
The caddy-with-tailscale package fails to build due to Go module path conflicts and Nix sandbox restrictions. The OAuth fork (chrishoage/caddy-tailscale) was never successfully built.

Options:
1. Use official plugin (no OAuth) and adjust auth
2. Properly vendor the OAuth fork dependencies  
3. Alternative proxy solution

## Resolution Plan
Created follow-up tasks to unblock this migration:
- task-4: Investigate OAuth implementations (compare PR #109 vs chrishoage fork)
- task-5: Create local fork with OAuth support
- task-6: Fix Nix package build
- task-7: Complete migration and testing

Task-3 blocked pending resolution of Caddy package build issue in task-4/5/6.
<!-- SECTION:NOTES:END -->
