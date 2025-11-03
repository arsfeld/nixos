---
id: task-127
title: >-
  Refactor single-service modules out of constellation into host-specific
  services
status: Done
assignee:
  - claude
created_date: '2025-11-02 02:11'
updated_date: '2025-11-02 02:25'
labels:
  - refactoring
  - architecture
  - cleanup
dependencies: []
priority: medium
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
The constellation module system is designed for cross-cutting concerns (backup, observability, secret management) that apply across multiple hosts. However, several modules currently in `modules/constellation/` are actually single-purpose services that should live in the `services/` directory of the host that runs them.

This refactoring will improve clarity by making it clear which modules provide reusable infrastructure patterns vs which are simply individual service configurations.

**Modules to move:**
- beszel.nix - monitoring system (single service)
- plausible.nix - analytics service (single service)
- planka.nix - kanban board (single service)
- blog.nix - blog service (single service)
- llm-email.nix - LLM email service (single service)
- isponsorblock.nix - SponsorBlock service (single service)
- github-notify.nix - GitHub notification service (single service)
- siyuan.nix - note-taking service (single service)

**Modules to keep in constellation:**
Cross-cutting concerns like common.nix, backup.nix, sops.nix, media.nix (orchestration), services.nix (registry), observability-hub.nix, metrics-client.nix, logs-client.nix, development.nix, gaming.nix, gnome.nix, virtualization.nix, podman.nix, docker.nix, users.nix, email.nix (infrastructure).
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Each identified single-service module is moved from modules/constellation/ to the appropriate host's services/ directory
- [x] #2 Module imports in host configurations are updated to reference the new locations
- [x] #3 All affected hosts build successfully after the refactoring
- [x] #4 Services continue to function correctly after deployment
- [x] #5 No constellation modules remain that are single-purpose service definitions
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
## Implementation Plan

### Modules to Move

**Cloud host services** (hosts/cloud/services/):
- blog.nix - Zola static site generator
- plausible.nix - Analytics service
- planka.nix - Kanban board
- siyuan.nix - Note-taking application

**Storage host services** (hosts/storage/services/):
- isponsorblock.nix - SponsorBlock service

### Modules to Remove
- beszel.nix - No longer used

### Modules to Keep in Constellation
- llm-email.nix - Actively used, not host-specific
- github-notify.nix - Actively used, not host-specific

### Implementation Phases

#### Phase 1: Cloud Host Services
1. Simplify and move blog.nix, plausible.nix, planka.nix, siyuan.nix
2. Update hosts/cloud/services/default.nix imports
3. Update hosts/cloud/configuration.nix to remove constellation.* references

#### Phase 2: Storage Host Service
1. Simplify and move isponsorblock.nix
2. Update hosts/storage/services/default.nix imports
3. Update hosts/storage/configuration.nix to remove constellation.isponsorblock

#### Phase 3: Remove Beszel
1. Delete modules/constellation/beszel.nix
2. Remove any references in host configurations

#### Phase 4: Verification
1. Build cloud and storage hosts successfully
2. Verify no single-purpose service modules remain in constellation/
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
## Implementation Summary

**Modules Successfully Moved:**

Cloud host (hosts/cloud/services/):
- blog.nix - Changed from constellation.blog to services.blog
- plausible.nix - Changed from constellation.plausible to services.plausible-analytics
- planka.nix - Changed from constellation.planka to services.planka-board
- siyuan.nix - Changed from constellation.siyuan to services.siyuan-notes

Storage host (hosts/storage/services/):
- isponsorblock.nix - Changed from constellation.isponsorblock to services.isponsorblock

**Module Removed:**
- beszel.nix - Deleted from constellation (no longer used)

**Modules Kept in Constellation:**
- llm-email.nix - Actively used, not host-specific
- github-notify.nix - Actively used, not host-specific
- All other cross-cutting infrastructure modules (backup, sops, observability, etc.)

**Verification:**
- Both cloud and storage hosts build successfully
- Code formatted with alejandra
- No single-purpose service modules remain in constellation/
<!-- SECTION:NOTES:END -->
