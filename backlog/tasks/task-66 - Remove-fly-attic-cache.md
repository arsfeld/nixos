---
id: task-66
title: Remove fly-attic cache
status: To Do
assignee: []
created_date: '2025-10-19 01:26'
updated_date: '2025-10-19 01:30'
labels: []
dependencies:
  - task-67
priority: medium
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Remove the fly-attic cache configuration from the NixOS setup. This likely involves removing cache references from flake configuration, any secrets related to fly-attic authentication, and ensuring no hosts depend on it.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Identify all references to fly-attic cache in the codebase
- [ ] #2 Remove fly-attic cache configuration from flake.nix or relevant configuration files
- [ ] #3 Remove any fly-attic related secrets
- [ ] #4 Verify no hosts or services depend on the fly-attic cache
- [ ] #5 Test that builds still work without fly-attic cache
- [ ] #6 Commit changes with clear explanation
<!-- AC:END -->
