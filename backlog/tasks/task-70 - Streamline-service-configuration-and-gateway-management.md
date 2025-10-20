---
id: task-70
title: Streamline service configuration and gateway management
status: To Do
assignee: []
created_date: '2025-10-19 04:00'
updated_date: '2025-10-20 13:28'
labels:
  - infrastructure
  - dx
  - refactor
dependencies: []
priority: medium
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
The current process for adding services to the media gateway is confusing and error-prone. It requires:

1. Determining whether to add to services.nix (native) or media.nix (containers)
2. Adding the service to the correct host section (cloud vs storage)
3. Manually adding to bypassAuth, funnels, and tailscaleExposed lists
4. Remembering to deploy to BOTH the service host AND cloud (for gateway updates)
5. Understanding the relationship between three different files (services.nix, media.nix, gateway.nix)

**Issues:**
- Easy to forget to add service to bypassAuth/funnels lists
- Easy to forget to deploy to cloud after adding a storage service
- No validation that service ports don't conflict
- No single source of truth for service configuration
- Duplicated information across multiple files

**Example:** When adding Attic, the service was defined in cache.nix, but also needed to be added to services.nix, and cloud needed to be redeployed even though Attic runs on storage.

**Potential improvements:**
- Single configuration location with automatic list generation
- Validation checks for port conflicts
- Deployment script that knows which hosts to update
- Service definition schema with clear fields for auth/funnel/tailscale options
- Automatic gateway updates without manual cloud deployment
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Adding a new service requires editing only one file
- [ ] #2 Service configuration clearly specifies auth, funnel, and tailscale options in one place
- [ ] #3 Port conflicts are automatically detected and reported
- [ ] #4 Deployment knows which hosts need updates (both service host and gateway)
- [ ] #5 Documentation is updated to reflect simplified process

- [ ] #6 Final schema must be compact and avoid verbose repetition (prefer defaults, minimal config)
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
## Implementation Overview

This refactoring will consolidate service definitions into a unified schema, eliminate manual list maintenance, add validation, and improve deployment workflow.

## Stage 1: Design unified service schema
**Goal**: Create a single service definition format that works for both native and containerized services
**Success Criteria**: 
- Schema type defined in NixOS module system
- Schema supports all current service options (port, host, bypassAuth, funnel, tailscale, etc.)
- Schema accommodates both native services and container-specific options
**Tests**:
- Schema validates correctly in NixOS
- Can represent existing services without loss of functionality
**Implementation Notes**:
- Create new module `modules/constellation/service-schema.nix` with type definitions
- Schema should include:
  - name (string)
  - host (string - cloud/storage)
  - port (int or null for auto-assignment)
  - type (enum: native, container)
  - auth.bypass (bool, default false)
  - auth.cors (bool, default false)
  - tailscale.expose (bool, default false)
  - tailscale.funnel (bool, default false)
  - container-specific: image, volumes, environment, devices, etc.
- Schema should auto-generate the lists (bypassAuth, funnels, tailscaleExposed)

## Stage 2: Migrate container services to unified schema
**Goal**: Convert media.nix container definitions to the new schema format
**Success Criteria**:
- All containerized services use new schema
- Existing container functionality preserved
- No manual list maintenance required
**Tests**:
- `nix build .#nixosConfigurations.storage.config.system.build.toplevel` succeeds
- All container services still generate correct podman configs
- Gateway receives same service definitions as before
**Implementation Notes**:
- Modify media.nix to use the new schema
- Container-specific options (image, volumes, mediaVolumes, devices) remain in schema
- Settings (bypassAuth, funnel) move to top-level schema fields
- Remove manual `addHost` function - schema handles this

## Stage 3: Migrate native services to unified schema
**Goal**: Convert services.nix native service definitions to the new schema format
**Success Criteria**:
- All native services use new schema
- bypassAuth, cors, funnels, tailscaleExposed lists automatically generated
- No manual list maintenance
**Tests**:
- `nix build .#nixosConfigurations.cloud.config.system.build.toplevel` succeeds
- `nix build .#nixosConfigurations.storage.config.system.build.toplevel` succeeds
- All services still accessible through gateway
- Authentication rules correctly applied
**Implementation Notes**:
- Refactor services.nix to use schema
- Remove hardcoded lists (bypassAuth, cors, funnels, tailscaleExposed)
- Auto-generate lists from service definitions using `filter` and `map`
- Preserve all existing service configurations

## Stage 4: Add port conflict validation
**Goal**: Detect and report port conflicts across all services
**Success Criteria**:
- Build fails with clear error if two services on same host use same port
- Error message identifies conflicting services
- Validation runs at evaluation time
**Tests**:
- Temporarily create duplicate port assignment - build should fail
- Error message clearly identifies both services and port
- Remove duplicate - build succeeds
**Implementation Notes**:
- Add validation function in service-schema.nix
- Group services by host, then check for duplicate ports
- Use `lib.assertMsg` or custom assertion to provide clear errors
- Run validation in config.media.gateway module

## Stage 5: Improve deployment workflow
**Goal**: Simplify deployment when adding/modifying services
**Success Criteria**:
- Documentation clearly explains single-file service addition
- Helper script/justfile command to deploy both service host and gateway
- Clear feedback about which hosts need deployment
**Tests**:
- Add new test service following docs
- Run deployment command
- Verify service accessible through gateway
**Implementation Notes**:
- Update justfile with `deploy-service` command that takes service name
- Command determines host from service definition
- Deploys to both service host and cloud (if different)
- Update CLAUDE.md with simplified workflow
- Add examples for both native and container services

## Stage 6: Update documentation
**Goal**: Document the new simplified workflow
**Success Criteria**:
- CLAUDE.md updated with new service addition process
- Clear examples for native and container services
- Migration guide for understanding changes
**Tests**:
- Follow docs to add a new native service - works as documented
- Follow docs to add a new container service - works as documented
- Validation catches port conflicts as documented
**Implementation Notes**:
- Update "Adding New Services" section in CLAUDE.md
- Add examples of service schema definitions
- Document automatic list generation
- Document port conflict validation
- Add troubleshooting section

## Dependencies
- All stages build on previous stage
- Stage 1 must complete before Stage 2 or 3
- Stages 2 and 3 can be done in parallel after Stage 1
- Stage 4 requires Stages 2 and 3 to be complete
- Stage 5 and 6 can be done in parallel after Stage 4

## Expected Benefits
- Single file edit to add new service (instead of 2-3 files)
- No manual list maintenance (bypassAuth, funnels, etc.)
- Compile-time port conflict detection
- Clear deployment workflow with helper commands
- Better developer experience and fewer errors
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Schema Design Decision: Containers must be explicitly marked with type = "container". Native services are the default (no type field needed). This makes the config easy to scan and understand at a glance.

Organizational Decision: Instead of one monolithic services file, use a directory structure with focused files (e.g., services/storage.nix, services/cloud.nix, or services/media.nix, services/dev.nix, services/monitoring.nix). This makes the config more maintainable and easier to navigate.
<!-- SECTION:NOTES:END -->
