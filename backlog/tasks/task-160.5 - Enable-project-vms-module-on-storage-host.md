---
id: task-160.5
title: Enable project-vms module on storage host
status: To Do
assignee: []
created_date: '2025-12-28 20:55'
updated_date: '2025-12-28 21:05'
labels:
  - feature
  - infrastructure
dependencies:
  - task-160.4
parent_task_id: task-160
priority: medium
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Modify `hosts/storage/configuration.nix` to enable project-vms module with appropriate configuration for the storage server.

## Configuration
```nix
constellation.projectVms = {
  enable = true;
  storageDir = "/mnt/storage/vms/projects";  # Use large storage array
  defaultMemory = 16384;  # 16GB - storage has plenty of RAM
  defaultCpus = 8;
  tailscaleAuthKeyFile = config.sops.secrets.tailscale-project-vm-key.path;
  sshPublicKey = "ssh-ed25519 AAAA...";  # Your public key
};
```

## Secret Reference
```nix
sops.secrets.tailscale-project-vm-key = {
  sopsFile = config.constellation.sops.commonSopsFile;
};
```

## Considerations
- Storage host has ample resources (RAM, CPU, disk)
- Use /mnt/storage for VM disks (large capacity)
- Higher default resources than desktop hosts
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Module enabled in hosts/storage/configuration.nix
- [ ] #2 Storage dir points to /mnt/storage path
- [ ] #3 Default memory/CPU set appropriately for server
- [ ] #4 Tailscale auth key secret path configured
- [ ] #5 SSH public key configured
- [ ] #6 Configuration builds successfully
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
## Blocked By

This task depends on task-160.4 (Tailscale auth key secret). The common.yaml sops file must be created first.

## Prepared Configuration

Once task-160.4 is complete, add this to `hosts/storage/configuration.nix`:

```nix
# Project Isolation VMs with Debian testing
# Provides isolated dev environments with Docker, Nix, Tailscale, Claude Code
sops.secrets.tailscale-project-vm-key = {
  sopsFile = config.constellation.sops.commonSopsFile;
  mode = "0400";
};

constellation.projectVms = {
  enable = true;
  storageDir = "/mnt/storage/vms/projects";  # Use large storage array
  defaultMemory = 16384;  # 16GB
  defaultCpus = 8;
  tailscaleAuthKeyFile = config.sops.secrets.tailscale-project-vm-key.path;
  sshPublicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBDeQP9ZHuDegrcgBEAuLpCWEK0v8eIBAgaLMSquCP0w arsfeld@gmail.com";
};
```

Place this after the `constellation.home-assistant.enable = true;` line (around line 34).
<!-- SECTION:NOTES:END -->
