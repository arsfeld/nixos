---
id: task-120.3
title: Refactor sops-nix PoC into constellation.sops module
status: Done
assignee: []
created_date: '2025-11-02 01:57'
updated_date: '2025-11-02 02:05'
labels: []
dependencies: []
parent_task_id: task-120
priority: medium
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Clean up the proof-of-concept sops-nix implementation by removing "poc" from naming, renaming the user key for consistency, and integrating it into the constellation module system for consistency with other infrastructure components.

Currently, sops configuration is host-specific in `hosts/cloud/sops.nix` and uses `secrets/sops/cloud-poc.yaml`. The user key is named `user_arsfeld` but should be `user_arosenfeld` for consistency. This should be refactored into a reusable constellation module that can be enabled on any host.

**Changes needed:**
1. Rename `secrets/sops/cloud-poc.yaml` to `secrets/sops/cloud.yaml`
2. Rename `user_arsfeld` to `user_arosenfeld` in `.sops.yaml`
3. Rekey all sops secrets to update the encrypted data with the new key name
4. Create `modules/constellation/sops.nix` module with enable option
5. Move sops configuration logic from `hosts/cloud/sops.nix` into the constellation module
6. Update `.sops.yaml` to reference the renamed file
7. Update cloud host to use `constellation.sops.enable = true;` instead of direct import
8. Make the module flexible to support different secrets per host

This will make sops-nix consistent with other constellation modules (backup, services, media, etc.) and easier to roll out to other hosts during the full migration.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 cloud-poc.yaml renamed to cloud.yaml throughout the codebase
- [x] #2 user_arsfeld renamed to user_arosenfeld in .sops.yaml
- [x] #3 All sops secrets rekeyed with updated key name
- [x] #4 constellation.sops module created with enable option
- [x] #5 cloud host uses constellation.sops.enable instead of direct sops.nix import
- [x] #6 Module supports host-specific secret file paths via options

- [x] #7 Cloud host successfully redeploys with new constellation module
- [x] #8 Documentation updated in CLAUDE.md to reflect constellation pattern
<!-- AC:END -->
