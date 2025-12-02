---
id: task-152.2
title: Migrate cloud secrets to sops-nix
status: To Do
assignee: []
created_date: '2025-11-30 18:12'
labels:
  - secrets
  - cloud
dependencies: []
parent_task_id: task-152
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Complete the migration of remaining cloud host secrets from ragenix to sops-nix.

Secrets to migrate (from secrets.nix):
- authelia-secrets.age
- dex-clients-tailscale-secret.age
- dex-clients-qui-secret.age
- lldap-env.age
- lldap-password.age
- restic-rest-cloud.age
- ghost-session-secret.age
- ghost-smtp-env.age
- ghost-session-env.age
- plausible-secret-key.age
- plausible-smtp-password.age
- plausible-admin-password.age
- planka-db-password.age
- planka-secret-key.age

Steps:
1. Decrypt each .age file using ragenix
2. Add values to secrets/sops/cloud.yaml
3. Re-encrypt cloud.yaml
4. Update host configuration to use sops.secrets instead of age.secrets
5. Test deployment
<!-- SECTION:DESCRIPTION:END -->
