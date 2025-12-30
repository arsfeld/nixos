---
id: doc-1
title: Project Isolation VMs (Debian Testing + libvirt)
type: other
created_date: '2025-12-28 04:13'
---
# Project Isolation VMs

## Problem Statement

Need isolated development environments for different projects, similar to exe.dev but running locally. Each project should have:
- Full Docker support (not docker-in-docker which is problematic)
- Pre-installed dev tools: Nix, Claude Code CLI, Tailscale
- Easy start/stop workflow
- SSH access via Tailscale from anywhere on the network

## Proposed Solution

Use Debian testing VMs with existing libvirt/QEMU infrastructure:
- **Base image**: Official Debian cloud images (qcow2)
- **Provisioning**: Cloud-init for Nix, Docker, Tailscale, Claude Code
- **Storage**: COW overlay disks for fast creation + separate project disk
- **Access**: Tailscale SSH (`project-<name>.bat-boa.ts.net`)

## Architecture

```
/var/lib/project-vms/
├── base/debian-testing.qcow2  (shared backing file)
├── myapp/
│   ├── disk.qcow2     (COW overlay for system)
│   └── project.qcow2  (persistent /home/dev/project)
└── webapp/
    └── ...

libvirt/QEMU + KVM
├── project-myapp VM  → Tailscale: project-myapp
└── project-webapp VM → Tailscale: project-webapp
```

## Implementation Components

### 1. NixOS Module (`modules/constellation/project-vms.nix`)
- Options: enable, storageDir, defaultMemory, defaultCpus, tailscaleAuthKeyFile, sshPublicKey, projects
- Depends on: constellation.virtualization
- Creates: Base image download service, CLI package

### 2. Cloud-init Template
- Creates `dev` user with SSH key and sudo
- Installs: docker.io, docker-compose, git, curl, vim, tmux, jq
- Runs: Nix installer, Tailscale setup, Claude Code via npm
- Mounts: /dev/vdb → /home/dev/project

### 3. CLI Tool (`project-vm` command)
Commands:
- `create <name> [memory] [cpus] [disk]` - Create new VM with COW overlay
- `start <name>` - Start VM
- `stop <name>` - Stop VM  
- `destroy <name>` - Remove VM and disks
- `ssh <name>` - SSH via Tailscale
- `list` - List all VMs
- `status <name>` - Show VM details

### 4. Secrets
- Tailscale auth key (reusable, pre-authorized, tag:project-vm)
- SSH public key for VM access

## Usage

```bash
# Download base image (one-time)
sudo systemctl start project-vm-base

# Create and start VM
sudo project-vm create myapp 16384 8 100G
sudo project-vm start myapp

# SSH in
ssh dev@project-myapp.bat-boa.ts.net

# Inside VM
docker run -it ubuntu bash   # Native Docker!
claude                       # Claude Code ready

# Stop when done
sudo project-vm stop myapp
```

## Files to Create/Modify

| File | Action |
|------|--------|
| `modules/constellation/project-vms.nix` | Create |
| `modules/constellation/project-vms/cloud-init.yaml` | Create |
| `packages/project-vm/default.nix` | Create |
| `secrets/sops/common.yaml` | Modify - add tailscale key |
| `hosts/storage/configuration.nix` | Modify - enable module |
| `hosts/raider/configuration.nix` | Modify - enable module |

## Design Decisions

1. **VMs over containers**: Docker-in-Docker is problematic; VMs provide native Docker
2. **Debian testing**: Recent packages, more stable than sid
3. **Cloud-init**: No custom image build step, standard provisioning
4. **COW overlays**: Fast VM creation, efficient storage
5. **Separate project disk**: Persists independently of system changes
6. **CLI-driven**: Create/destroy on demand vs declarative in NixOS config

## Open Questions

- Should VMs auto-start on host boot? (Currently: no)
- Backup strategy for project disks?
- Base image update frequency?

## References

- Existing libvirt module: `modules/constellation/virtualization.nix`
- Tailscale pattern: `modules/constellation/vpn-exit-nodes.nix`
- Debian cloud images: https://cloud.debian.org/images/cloud/
