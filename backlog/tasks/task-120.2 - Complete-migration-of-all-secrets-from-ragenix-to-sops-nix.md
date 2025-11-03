---
id: task-120.2
title: Complete migration of all secrets from ragenix to sops-nix
status: To Do
assignee: []
created_date: '2025-10-31 19:07'
updated_date: '2025-10-31 19:08'
labels: []
dependencies:
  - task-120.1
parent_task_id: task-120
priority: medium
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
After validating the PoC, migrate all remaining secrets from ragenix to sops-nix. This includes updating all service configurations to reference sops secrets, migrating all encrypted secret files, and removing ragenix from the system.

This task should only begin after the PoC is successfully validated and any issues identified during the PoC are resolved.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 All secrets from secrets/secrets.nix are migrated to sops format
- [ ] #2 All service configurations are updated to use sops secrets instead of ragenix
- [ ] #3 All hosts can access their required secrets after deployment
- [ ] #4 ragenix is removed from flake inputs and all related configuration is cleaned up
- [ ] #5 Old .age secret files are archived or removed
- [ ] #6 CLAUDE.md is updated to remove ragenix references and document sops-nix as the standard
- [ ] #7 All hosts are successfully deployed with sops-nix secrets
<!-- AC:END -->
