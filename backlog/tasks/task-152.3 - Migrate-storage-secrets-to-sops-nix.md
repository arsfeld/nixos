---
id: task-152.3
title: Migrate storage secrets to sops-nix
status: To Do
assignee: []
created_date: '2025-11-30 18:12'
labels:
  - secrets
  - storage
dependencies: []
parent_task_id: task-152
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Create secrets/sops/storage.yaml and migrate all storage host secrets.

Secrets to migrate:
- bitmagnet-env.age
- qbittorrent-pia.age
- finance-tracker-env.age
- romm-env.age
- ohdio-env.age
- qui-oidc-env.age
- immich-oidc-secret.age
- openarchiver-env.age
- mediamanager-env.age
- mydia-env.age
- airvpn-wireguard.age
- transmission-openvpn-pia.age
- transmission-openvpn-airvpn.age
- attic-credentials.age
- attic-server-token.age
- tailscale-env.age (shared with cloud)
- github-token.age (shared with raider)

Steps:
1. Enable constellation.sops on storage host
2. Create secrets/sops/storage.yaml
3. Decrypt and migrate each secret
4. Update host configuration
5. Test deployment
<!-- SECTION:DESCRIPTION:END -->
