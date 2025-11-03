---
id: task-120.1
title: Implement sops-nix PoC with a subset of secrets
status: Done
assignee: []
created_date: '2025-10-31 19:07'
updated_date: '2025-10-31 21:25'
labels: []
dependencies: []
parent_task_id: task-120
priority: medium
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Create a proof of concept for sops-nix by migrating a small subset of non-critical secrets. This will validate the approach, tooling, and workflow before committing to a full migration.

Select 2-3 simple secrets (like API tokens or non-critical service credentials) to migrate. Set up sops-nix integration in the flake, configure age keys, and verify that secrets can be encrypted, decrypted, and deployed to hosts correctly.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 sops-nix is added to flake inputs and integrated into the NixOS configuration
- [x] #2 Age keys are properly configured for all hosts
- [x] #3 2-3 test secrets are successfully encrypted with sops
- [x] #4 Test secrets deploy correctly to target hosts and are accessible by services
- [x] #5 Documented the sops workflow in CLAUDE.md for creating/editing/deploying secrets
- [x] #6 PoC is validated on at least one host before proceeding to full migration
<!-- AC:END -->
