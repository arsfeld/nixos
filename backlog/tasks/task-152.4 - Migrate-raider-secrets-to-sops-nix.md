---
id: task-152.4
title: Migrate raider secrets to sops-nix
status: To Do
assignee: []
created_date: '2025-11-30 18:12'
labels:
  - secrets
  - raider
dependencies: []
parent_task_id: task-152
priority: medium
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Create secrets/sops/raider.yaml and migrate raider host secrets.

Secrets to migrate:
- harmonia-cache-key.age
- stash-jwt-secret.age
- stash-session-secret.age
- stash-password.age
- github-token.age (shared with storage)

Steps:
1. Enable constellation.sops on raider host
2. Create secrets/sops/raider.yaml
3. Decrypt and migrate each secret
4. Update host configuration
5. Test deployment
<!-- SECTION:DESCRIPTION:END -->
