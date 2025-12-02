---
id: task-152.1
title: Add missing host keys to .sops.yaml
status: To Do
assignee: []
created_date: '2025-11-30 18:12'
labels:
  - infrastructure
  - secrets
dependencies: []
parent_task_id: task-152
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Add age keys for remaining hosts (cottage, r2s, raspi3, router) to `.sops.yaml` and create corresponding creation rules.

Current hosts configured: cloud, storage, raider
Missing hosts: cottage, r2s, raspi3, router

Steps:
1. Convert SSH host keys to age keys using `ssh-to-age`
2. Add key anchors to the keys section
3. Add creation rules for each host's secrets file
<!-- SECTION:DESCRIPTION:END -->
