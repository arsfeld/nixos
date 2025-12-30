---
id: task-160.1
title: Create NixOS module for project-vms
status: Done
assignee:
  - '@claude'
created_date: '2025-12-28 20:55'
updated_date: '2025-12-28 21:02'
labels:
  - feature
  - infrastructure
dependencies: []
parent_task_id: task-160
priority: medium
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Create `modules/constellation/project-vms.nix` with options for enable, storageDir, defaultMemory, defaultCpus, tailscaleAuthKeyFile, sshPublicKey, and projects attrset.

## Module Structure
```nix
options.constellation.projectVms = {
  enable = mkEnableOption "project isolation VMs";
  storageDir = mkOption { type = path; default = "/var/lib/project-vms"; };
  defaultMemory = mkOption { type = int; default = 8192; }; # MB
  defaultCpus = mkOption { type = int; default = 4; };
  tailscaleAuthKeyFile = mkOption { type = path; };
  sshPublicKey = mkOption { type = str; };
  projects = mkOption { type = attrsOf projectType; default = {}; };
};
```

## Implementation Details
- Depends on `constellation.virtualization` module
- Creates systemd oneshot service to download Debian cloud image
- Sets up directory structure at storageDir
- Installs project-vm CLI package
- Generates cloud-init ISO template
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Module defines all required options with sensible defaults
- [x] #2 Creates systemd service to download Debian cloud image to base/
- [x] #3 Sets up /var/lib/project-vms/ directory structure
- [x] #4 Integrates with existing virtualization module
- [x] #5 Installs project-vm CLI package when enabled
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
## Implementation Notes

Created `modules/constellation/project-vms.nix` with:

### Module Options
- `enable` - Enable project VMs
- `storageDir` - Base directory (default: `/var/lib/project-vms`)
- `defaultMemory` - Default RAM in MB (default: 8192)
- `defaultCpus` - Default vCPUs (default: 4)
- `defaultDiskSize` - Default project disk (default: 50G)
- `tailscaleAuthKeyFile` - Path to Tailscale auth key file
- `sshPublicKey` - SSH key for dev user
- `projects` - Optional declarative project definitions

### Systemd Services
- `project-vm-base` - Downloads Debian testing cloud image
- `libvirtd-config` - Ensures libvirt default network exists

### CLI Tool
- Embedded `project-vm` script with full functionality
- Commands: create, start, stop, destroy, ssh, list, status, console

### Integration
- Automatically enables `constellation.virtualization`
- Sets up directory structure via tmpfiles
<!-- SECTION:NOTES:END -->
