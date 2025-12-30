---
id: task-160.2
title: Create cloud-init provisioning template
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
Create `modules/constellation/project-vms/cloud-init.yaml` that provisions VMs with dev user, SSH key, Docker, Nix, Tailscale, and Claude Code.

## User Configuration
- Create `dev` user with passwordless sudo
- Add SSH authorized key from module config
- Set up proper home directory permissions

## Package Installation
```yaml
packages:
  - docker.io
  - docker-compose
  - git
  - curl
  - vim
  - tmux
  - jq
  - build-essential
```

## Runcmd Scripts
1. Add dev user to docker group
2. Run Nix multi-user installer
3. Configure Tailscale with auth key and hostname
4. Install Claude Code via npm (after Nix provides node)
5. Mount /dev/vdb to /home/dev/project (via fstab or mount)

## Disk Configuration
- /dev/vdb formatted as ext4 on first boot
- Mounted at /home/dev/project
- Owned by dev:dev
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Creates dev user with sudo and SSH key access
- [x] #2 Installs docker.io, docker-compose, git, curl, vim, tmux, jq
- [x] #3 Runs Nix multi-user installer successfully
- [x] #4 Sets up Tailscale with provided auth key and custom hostname
- [x] #5 Installs Claude Code CLI via npm
- [x] #6 Mounts /dev/vdb to /home/dev/project with correct permissions
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
## Implementation Notes

Cloud-init configuration is embedded in the `generate_cloud_init` function within `project-vms.nix` CLI script rather than a separate template file. This approach:

1. Allows dynamic injection of configuration values (SSH key, Tailscale auth key, hostname)
2. Keeps everything in a single module file
3. Uses the same cloud-init format as specified

### User Configuration
- Creates `dev` user with passwordless sudo (`ALL=(ALL) NOPASSWD:ALL`)
- SSH key injected from `cfg.sshPublicKey`
- Shell set to `/bin/bash`

### Packages Installed
- docker.io, docker-compose
- git, curl, vim, tmux, jq
- htop, build-essential, xz-utils

### Runcmd Scripts
1. `usermod -aG docker dev` - Docker access
2. Nix multi-user installer with `--daemon --yes`
3. Tailscale install and `tailscale up` with auth key and `--ssh`
4. Node.js LTS via nodesource + `npm install -g @anthropic-ai/claude-code`

### Disk Setup
- Creates ext4 on `/dev/vdb` if not already formatted
- Mounts at `/home/dev/project`
- Adds fstab entry for persistence
- Ownership set to `dev:dev`
<!-- SECTION:NOTES:END -->
