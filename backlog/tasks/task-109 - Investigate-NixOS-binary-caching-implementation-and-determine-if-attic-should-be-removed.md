---
id: task-109
title: >-
  Investigate NixOS binary caching implementation and determine if attic should
  be removed
status: To Do
assignee: []
created_date: '2025-10-31 01:24'
labels:
  - infrastructure
  - nix
  - caching
  - storage
  - investigation
dependencies: []
priority: medium
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Attic binary cache was found running on storage:8080, but it was thought to be disabled or not in use. Need to investigate the current caching setup and determine the proper configuration.

## Background
- Found atticd service running on storage:8080 (configured in hosts/storage/cache.nix)
- Attic was disabled to free up port 8080 for qbittorrent WebUI
- Unclear if attic is actually being used or if there's another caching solution in place

## Investigation Tasks
1. Check if any hosts are configured to use storage's attic cache as a substituter
2. Verify if GitHub Actions uses attic or another cache (Magic Nix Cache?)
3. Check modules/constellation/common.nix for cache configuration
4. Determine if attic was replaced by another solution
5. Review git history to understand when/why attic was set up

## Questions to Answer
- Is attic actually being used by any systems?
- Should attic be completely removed from storage/cache.nix?
- Is there another binary caching solution in place?
- Should we use a different cache (harmonia, nix-serve, cachix)?
- What's the current cache URL (https://attic.arsfeld.one)?

## Related Files
- hosts/storage/cache.nix - Attic server configuration
- modules/constellation/common.nix - Likely has cache substituter config
- flake.nix - Check for cache configuration
<!-- SECTION:DESCRIPTION:END -->
