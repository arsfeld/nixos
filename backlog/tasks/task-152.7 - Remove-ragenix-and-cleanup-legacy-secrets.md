---
id: task-152.7
title: Remove ragenix and cleanup legacy secrets
status: To Do
assignee: []
created_date: '2025-11-30 18:12'
labels:
  - cleanup
  - secrets
dependencies: []
parent_task_id: task-152
priority: low
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
After all hosts are migrated, remove ragenix configuration and legacy .age files.

Steps:
1. Verify all hosts deploy successfully with sops-nix
2. Remove ragenix from flake inputs
3. Delete all secrets/*.age files
4. Delete secrets/secrets.nix
5. Remove ragenix references from modules
6. Update CLAUDE.md documentation
7. Final deployment test on all hosts
<!-- SECTION:DESCRIPTION:END -->
