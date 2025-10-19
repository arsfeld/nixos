---
id: task-70
title: Streamline service configuration and gateway management
status: To Do
assignee: []
created_date: '2025-10-19 04:00'
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
<!-- AC:END -->
