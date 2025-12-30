---
id: task-160.6
title: Enable project-vms module on raider host
status: To Do
assignee: []
created_date: '2025-12-28 20:55'
updated_date: '2025-12-28 21:06'
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
Modify `hosts/raider/configuration.nix` to enable project-vms module with appropriate configuration for the desktop/laptop.

## Configuration
```nix
constellation.projectVms = {
  enable = true;
  storageDir = "/var/lib/project-vms";  # Local storage
  defaultMemory = 8192;   # 8GB - balance with host usage
  defaultCpus = 4;        # Leave resources for host
  tailscaleAuthKeyFile = config.sops.secrets.tailscale-project-vm-key.path;
  sshPublicKey = "ssh-ed25519 AAAA...";
};
```

## Secret Reference
```nix
sops.secrets.tailscale-project-vm-key = {
  sopsFile = config.constellation.sops.commonSopsFile;
};
```

## Considerations
- Desktop has limited resources compared to storage
- Lower defaults to avoid impacting host performance
- Local storage (/var/lib) for VM disks
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Module enabled in hosts/raider/configuration.nix
- [ ] #2 Storage dir set to /var/lib/project-vms
- [ ] #3 Default memory/CPU balanced for desktop use
- [ ] #4 Tailscale auth key and SSH key configured
- [ ] #5 Configuration builds successfully
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
## Blocked By

This task depends on task-160.4 (Tailscale auth key secret). The common.yaml sops file must be created first.

## Prepared Configuration

Once task-160.4 is complete, add this to `hosts/raider/configuration.nix`:

```nix
# Project Isolation VMs with Debian testing
# Provides isolated dev environments with Docker, Nix, Tailscale, Claude Code
sops.secrets.tailscale-project-vm-key = {
  sopsFile = config.constellation.sops.commonSopsFile;
  mode = "0400";
};

constellation.projectVms = {
  enable = true;
  storageDir = "/var/lib/project-vms";  # Local storage
  defaultMemory = 8192;   # 8GB - balance with host usage
  defaultCpus = 4;        # Leave resources for host
  tailscaleAuthKeyFile = config.sops.secrets.tailscale-project-vm-key.path;
  sshPublicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBDeQP9ZHuDegrcgBEAuLpCWEK0v8eIBAgaLMSquCP0w arsfeld@gmail.com";
};
```

**Note:** Raider needs `constellation.sops.enable = true;` if not already enabled.
<!-- SECTION:NOTES:END -->
