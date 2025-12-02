---
id: task-152.5
title: Create common.yaml for shared secrets
status: To Do
assignee: []
created_date: '2025-11-30 18:12'
labels:
  - secrets
  - infrastructure
dependencies: []
parent_task_id: task-152
priority: medium
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Create secrets/sops/common.yaml for secrets shared across multiple hosts.

Shared secrets to migrate:
- borg-passkey.age (all systems)
- cloudflare.age (all systems)
- github-runner-token.age (all systems)
- gluetun-pia.age (all systems)
- homepage-env.age (all systems)
- rclone-idrive.age (all systems)
- restic-password.age (all systems)
- restic-truenas.age (all systems)
- idrive-env.age (all systems)
- smtp_password.age (all systems)
- tailscale-key.age (all systems)
- google-api-key.age (all systems)
- minio-credentials.age (all systems)
- restic-rest-auth.age (all systems)
- restic-cottage-minio.age (all systems)

Steps:
1. Ensure .sops.yaml has rule for common.yaml with all host keys
2. Create secrets/sops/common.yaml
3. Migrate shared secrets
4. Update constellation.sops module to support commonSopsFile
<!-- SECTION:DESCRIPTION:END -->
