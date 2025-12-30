---
id: task-160.3
title: Create project-vm CLI tool
status: Done
assignee:
  - '@claude'
created_date: '2025-12-28 20:55'
updated_date: '2025-12-28 21:04'
labels:
  - feature
  - infrastructure
dependencies: []
parent_task_id: task-160
priority: medium
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Create `packages/project-vm/default.nix` with bash script implementing VM management commands.

## Commands

### `project-vm create <name> [memory] [cpus] [disk]`
- Create qcow2 overlay disk backed by base image
- Create separate project disk (default 50G)
- Generate cloud-init ISO with user-data and meta-data
- Define libvirt domain XML

### `project-vm start <name>`
- Start VM via `virsh start`
- Wait for cloud-init to complete (optional)

### `project-vm stop <name>`
- Graceful shutdown via `virsh shutdown`
- Timeout fallback to `virsh destroy`

### `project-vm destroy <name>`
- Undefine VM via `virsh undefine`
- Remove overlay disk, project disk, cloud-init ISO
- Optionally keep project disk with `--keep-data`

### `project-vm ssh <name>`
- SSH to `dev@project-<name>.bat-boa.ts.net`

### `project-vm list`
- List all project-* VMs with status

### `project-vm status <name>`
- Show VM details: state, memory, CPUs, IP addresses

## Dependencies
- virsh, qemu-img, genisoimage/mkisofs
- Wrapped with proper PATH in Nix package
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 create command builds COW overlay from base image + separate project disk
- [x] #2 start command boots VM with cloud-init attached
- [x] #3 stop command gracefully shuts down VM with timeout fallback
- [x] #4 destroy command removes VM definition and disks (with --keep-data option)
- [x] #5 ssh command connects via Tailscale hostname
- [x] #6 list command shows all project VMs with running status
- [x] #7 status command displays VM details (memory, CPU, state)
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
## Implementation Notes

CLI tool is embedded in `project-vms.nix` as a `writeShellApplication`. All commands implemented:

### Commands
- `create <name> [memory] [cpus] [disk]` - Creates COW overlay + project disk + cloud-init ISO + libvirt domain
- `start <name>` - Boots VM via virsh start
- `stop <name>` - Graceful shutdown with 60s timeout, fallback to force destroy
- `destroy <name> [--keep-data]` - Removes VM, optionally preserves project.qcow2
- `ssh <name>` - Connects via `ssh dev@project-<name>.bat-boa.ts.net`
- `list` - Lists all project VMs with state
- `status <name>` - Shows virsh dominfo + disk sizes
- `console <name>` - Attaches to VM serial console

### Runtime Dependencies
- libvirt, qemu, cloud-utils, coreutils, gawk, gnused, gnugrep, openssh, jq

### Note
Decided to embed CLI in module rather than separate package to keep configuration values (storageDir, etc.) directly accessible without passing them via environment or flags.
<!-- SECTION:NOTES:END -->
