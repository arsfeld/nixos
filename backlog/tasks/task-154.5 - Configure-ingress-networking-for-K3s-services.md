---
id: task-154.5
title: Configure ingress/networking for K3s services
status: To Do
assignee: []
created_date: '2025-12-01 03:43'
labels:
  - kubernetes
  - networking
dependencies: []
parent_task_id: task-154
priority: medium
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Set up networking so K3s services are accessible via the existing Caddy gateway.

## Approach
- Use NodePort services or K3s LoadBalancer
- Add upstream entries to Caddy for K3s services
- Consider using Kubernetes Ingress with Caddy ingress controller
- Ensure services are accessible via *.arsfeld.one domains

## Alternative
- Install ingress-nginx inside K3s and have Caddy proxy to it
<!-- SECTION:DESCRIPTION:END -->
