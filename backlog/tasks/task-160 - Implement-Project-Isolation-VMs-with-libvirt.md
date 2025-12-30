---
id: task-160
title: Implement Project Isolation VMs with libvirt
status: In Progress
assignee: []
created_date: '2025-12-28 20:54'
updated_date: '2025-12-28 21:06'
labels:
  - feature
  - infrastructure
dependencies: []
priority: medium
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Create isolated development environments using Debian testing VMs with native Docker support, Nix, Claude Code CLI, and Tailscale SSH access. VMs use COW overlays for efficient storage and cloud-init for provisioning.

**Source document:** doc-1 (Project Isolation VMs - Debian Testing + libvirt)

## Architecture
- Base image: Debian testing cloud qcow2
- Provisioning: Cloud-init for Nix, Docker, Tailscale, Claude Code
- Storage: COW overlay disks + separate project disk
- Access: Tailscale SSH (project-<name>.bat-boa.ts.net)
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 NixOS module created with all required options
- [x] #2 Cloud-init template provisions VMs with Docker, Nix, Tailscale, Claude Code
- [x] #3 CLI tool supports create/start/stop/destroy/ssh/list/status commands
- [ ] #4 VMs accessible via Tailscale SSH
- [ ] #5 Docker runs natively inside VMs
- [ ] #6 Project disk persists independently of system changes
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
## Progress Summary

### Completed
- **task-160.1**: NixOS module created with all options
- **task-160.2**: Cloud-init template implemented (embedded in module)
- **task-160.3**: CLI tool with all commands

### Pending User Action
- **task-160.4**: Requires user to create Tailscale auth key and sops secret

### Blocked
- **task-160.5**: Storage host config - waiting on 160.4
- **task-160.6**: Raider host config - waiting on 160.4
- **task-160.7**: Testing - waiting on deployment

### Key Files Created
- `modules/constellation/project-vms.nix` - Main module with embedded CLI
<!-- SECTION:NOTES:END -->
