---
id: task-160.7
title: Test and validate full project-vm workflow
status: To Do
assignee: []
created_date: '2025-12-28 20:55'
updated_date: '2025-12-28 21:06'
labels:
  - feature
  - infrastructure
dependencies:
  - task-160.4
  - task-160.5
  - task-160.6
parent_task_id: task-160
priority: medium
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
End-to-end testing of VM creation, provisioning, access, and destruction. Verify all components work together.

## Test Sequence

### 1. Base Image Download
```bash
sudo systemctl start project-vm-base
ls -la /var/lib/project-vms/base/debian-testing.qcow2
```

### 2. VM Creation
```bash
sudo project-vm create test-vm 8192 4 50G
# Should complete in < 30 seconds (COW overlay)
```

### 3. VM Start & Provisioning
```bash
sudo project-vm start test-vm
# Wait for cloud-init (check via console or logs)
```

### 4. Tailscale Access
```bash
# Verify VM appears in tailnet
tailscale status | grep project-test-vm
# SSH access
ssh dev@project-test-vm.bat-boa.ts.net
```

### 5. Inside VM Verification
```bash
# Docker works natively
docker run --rm hello-world
docker run -it ubuntu bash

# Nix available
nix --version
nix-shell -p cowsay --run "cowsay hello"

# Claude Code works
claude --version

# Project disk mounted
df -h /home/dev/project
touch /home/dev/project/test-file
```

### 6. Persistence Test
```bash
# Stop and recreate system disk, keep project disk
sudo project-vm stop test-vm
sudo project-vm destroy test-vm --keep-data
sudo project-vm create test-vm
sudo project-vm start test-vm
# Verify test-file still exists
ssh dev@project-test-vm cat /home/dev/project/test-file
```

### 7. Full Cleanup
```bash
sudo project-vm destroy test-vm
# Verify all resources removed
virsh list --all | grep test-vm  # Should be empty
ls /var/lib/project-vms/test-vm/  # Should not exist
```
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Base image downloads successfully
- [ ] #2 VM creates with COW overlay in < 30 seconds
- [ ] #3 Cloud-init completes all provisioning steps
- [ ] #4 SSH via Tailscale works (project-<name>.bat-boa.ts.net)
- [ ] #5 Docker runs containers natively (not docker-in-docker)
- [ ] #6 Nix package manager is functional
- [ ] #7 Claude Code CLI is installed and working
- [ ] #8 Project disk persists across VM recreation
- [ ] #9 Destroy command properly cleans up all resources
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
## Prerequisites

This testing task requires:
1. Task 160.4 complete (Tailscale auth key secret created)
2. Task 160.5 or 160.6 complete (module enabled on at least one host)
3. Host deployed with new configuration

## Ready When

Can proceed once:
- `secrets/sops/common.yaml` exists with `tailscale-project-vm-key`
- Host configuration is deployed
- `project-vm` command is available on the host
<!-- SECTION:NOTES:END -->
