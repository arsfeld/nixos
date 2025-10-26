---
id: task-92
title: >-
  Update justfile to include nixos-rebuild deployment commands alongside
  deploy-rs
status: Done
assignee: []
created_date: '2025-10-25 00:15'
updated_date: '2025-10-25 20:07'
labels:
  - deployment
  - tooling
  - workaround
dependencies: []
priority: medium
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Add nixos-rebuild-based deployment commands to the justfile as an alternative to deploy-rs. This provides a workaround for the deploy-rs incompatibility with Nix 2.32+ (issue #340).

The justfile should include:
- A new recipe using nixos-rebuild with --target-host for deployments (e.g., `deploy-nixos-rebuild` or `deploy-direct`)
- Keep the existing deploy-rs commands for when the issue is fixed
- Similar patterns for boot, build, etc.
- Documentation in comments explaining when to use each method

Example working command:
```
nixos-rebuild switch --flake .#storage --target-host root@storage.bat-boa.ts.net --use-remote-sudo
```

Reference: https://github.com/serokell/deploy-rs/issues/340
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 justfile includes new nixos-rebuild-based deployment commands (deploy-direct, boot-direct, test-direct)
- [ ] #2 Existing deploy-rs commands remain unchanged
- [ ] #3 Commands include clear documentation comments explaining when to use each method
- [ ] #4 Commands support all hosts via .bat-boa.ts.net addresses
- [ ] #5 Commands follow same patterns as existing deployment recipes
<!-- AC:END -->
