---
id: task-154.2
title: Set up persistent storage for K3s workloads
status: To Do
assignee: []
created_date: '2025-12-01 03:43'
labels:
  - kubernetes
  - storage
dependencies: []
parent_task_id: task-154
priority: medium
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Configure storage provisioner for K3s to support PersistentVolumeClaims for databases.

## Options to evaluate
- Local-path provisioner (K3s default) - simple, single-node
- Longhorn - if planning multi-node with replication later
- NFS provisioner - if storage host should provide volumes

## Requirements
- PVCs for Postgres databases
- PVCs for Redis persistence (optional)
- Backup strategy for PVs
<!-- SECTION:DESCRIPTION:END -->
