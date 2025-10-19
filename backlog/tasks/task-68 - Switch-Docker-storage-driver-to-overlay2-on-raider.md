---
id: task-68
title: Switch Docker storage driver to overlay2 on raider
status: Done
assignee: []
created_date: '2025-10-19 01:31'
updated_date: '2025-10-19 01:40'
labels: []
dependencies: []
priority: medium
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Change the Docker storage driver on the raider host to use overlay2. The overlay2 storage driver is generally more performant and efficient than other storage drivers like vfs or devicemapper.

This will require:
- Checking the current storage driver configuration
- Backing up any important containers/images if needed
- Updating the NixOS Docker configuration to use overlay2
- Testing that Docker works correctly with the new storage driver

Note: Changing storage drivers may require rebuilding containers/images as the storage is not automatically migrated.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Identify current Docker storage driver on raider
- [x] #2 Document any existing containers/images that need to be preserved
- [x] #3 Update raider's NixOS configuration to use overlay2 storage driver
- [x] #4 Deploy the configuration change to raider
- [x] #5 Verify Docker daemon starts correctly with overlay2
- [x] #6 Test Docker functionality (pull image, run container)
- [x] #7 Document any containers/images that need to be recreated
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
## Implementation Plan

1. Add overlay2 storage driver configuration to raider's NixOS config
   - File: /home/arosenfeld/Code/nixos/hosts/raider/configuration.nix
   - Add: virtualisation.docker.storageDriver = "overlay2";
   
2. Build configuration locally to verify it compiles

3. Deploy to raider using just deploy raider

4. Verify Docker daemon starts correctly with overlay2

Note: No data migration needed - user confirmed we don't need to preserve existing containers/images.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Deployment completed successfully. Updated raider SSH key in secrets.nix from old key to ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIE7ayPDvZPe5h8rWjmRn2GMCRaMvE4Lhxxd2JjhJFai3. Rekeyed all secrets to include new raider key. Deployed configuration with virtualisation.docker.storageDriver = "overlay2" added to /home/arosenfeld/Code/nixos/hosts/raider/configuration.nix:23

User verified Docker daemon is running correctly with overlay2 storage driver. Docker functionality tested successfully. No containers needed to be recreated as none were defined in the NixOS configuration.
<!-- SECTION:NOTES:END -->
