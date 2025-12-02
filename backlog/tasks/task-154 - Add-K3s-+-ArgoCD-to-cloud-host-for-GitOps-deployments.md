---
id: task-154
title: Add K3s + ArgoCD to cloud host for GitOps deployments
status: To Do
assignee: []
created_date: '2025-12-01 03:43'
labels:
  - infrastructure
  - kubernetes
  - gitops
dependencies: []
priority: medium
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Set up a lightweight Kubernetes cluster on the cloud host using K3s, with ArgoCD for GitOps-based deployments. This will enable deploying product services (web apps + Postgres/Redis) independently via GitHub Actions, without touching the NixOS repo.

## Architecture
- K3s single-node cluster on cloud host (can add agents later)
- ArgoCD for GitOps syncing from product repos
- Each product owns its own manifests in its repo
- ArgoCD Applications bootstrap repo for registering new products

## Future Expansion
- Add K3s agents on other VPS hosts (storage, other Debian VPS)
- Migrate services from Coolify to K3s
<!-- SECTION:DESCRIPTION:END -->
