---
id: task-34
title: Deploy Caddy Tailscale bind configuration to cloud host
status: To Do
assignee: []
created_date: '2025-10-16 14:12'
labels:
  - caddy-tailscale
  - oauth
  - gateway
  - tailscale
  - cloud
dependencies:
  - task-33
priority: medium
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
## Description

Apply the same Caddy-Tailscale virtual host binding configuration to the cloud host that was successfully implemented on storage in task-33.

## Background

Task-33 successfully configured storage to use `bind tailscale/storage` for all virtual hosts, reducing from 82 individual Tailscale nodes to 1 Caddy-managed node. This resulted in:
- CPU usage reduction to 0.1%
- Single ephemeral Tailscale node
- 72 services accessible through one node

The cloud host likely has a similar configuration and will benefit from the same optimization.

## Implementation

The configuration changes are already in the shared modules:
- `modules/media/__utils.nix` - Contains the bind directive
- `modules/media/gateway.nix` - Contains the OAuth tag configuration

Simply need to deploy to cloud and verify the results.

## Expected Outcome

- Single `cloud` Tailscale node created
- All cloud services accessible through the node
- Reduced CPU usage similar to storage
- Ephemeral node with OAuth authentication
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Single 'cloud' Tailscale node visible in admin console
- [ ] #2 Node is ephemeral
- [ ] #3 All cloud services accessible through the node
- [ ] #4 CPU usage reduced compared to baseline
- [ ] #5 No errors in Caddy logs
- [ ] #6 Services accessible from Tailnet
- [ ] #7 Virtual hosts properly bind to tailscale/cloud
<!-- AC:END -->
