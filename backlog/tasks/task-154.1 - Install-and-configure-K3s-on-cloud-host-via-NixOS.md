---
id: task-154.1
title: Install and configure K3s on cloud host via NixOS
status: To Do
assignee: []
created_date: '2025-12-01 03:43'
labels:
  - kubernetes
  - nixos
dependencies: []
parent_task_id: task-154
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Enable K3s on the cloud host using the NixOS `services.k3s` module.

## Requirements
- K3s in server mode (single node for now)
- Disable Traefik (already using Caddy as gateway)
- Disable servicelb (use host networking or NodePort)
- Configure flannel for CNI
- Ensure K3s works with Tailscale networking
- Store kubeconfig securely
<!-- SECTION:DESCRIPTION:END -->
