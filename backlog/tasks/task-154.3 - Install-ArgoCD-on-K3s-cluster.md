---
id: task-154.3
title: Install ArgoCD on K3s cluster
status: To Do
assignee: []
created_date: '2025-12-01 03:43'
labels:
  - kubernetes
  - gitops
  - argocd
dependencies: []
parent_task_id: task-154
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Deploy ArgoCD to the K3s cluster for GitOps management.

## Requirements
- Install via Helm or raw manifests
- Expose ArgoCD UI via Caddy gateway (argocd.arsfeld.one)
- Configure ArgoCD to use GitHub repos (SSH or HTTPS)
- Set up initial admin credentials (store in sops-nix)
- Consider SSO integration with existing auth (optional)
<!-- SECTION:DESCRIPTION:END -->
