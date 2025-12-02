---
id: task-152.6
title: 'Migrate minor host secrets (cottage, r2s, raspi3, router)'
status: To Do
assignee: []
created_date: '2025-11-30 18:12'
labels:
  - secrets
dependencies: []
parent_task_id: task-152
priority: low
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Enable sops-nix on remaining minor hosts and ensure they can access common secrets.

Hosts:
- cottage: restic-rest-micro.age (host-specific)
- r2s, raspi3, router: Only use shared secrets from common.yaml

Steps:
1. Enable constellation.sops on each host
2. Create cottage.yaml for cottage-specific secrets
3. Configure hosts to use common.yaml for shared secrets
4. Test deployments
<!-- SECTION:DESCRIPTION:END -->
