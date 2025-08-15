# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Overview

This is a personal NixOS configuration repository that manages multiple machines using Nix Flakes. It includes configurations for servers (storage, cloud), embedded devices (R2S, Raspberry Pi), and desktop systems.

## Key Commands

### Development Environment
```bash
# Enter development shell (required for most operations)
nix develop
```

### Secret Management
```bash
# Edit an encrypted secret
agenix -e secrets/secret-name.age

# View decrypted secret (use with caution)
cd secrets && age -d -i ~/.ssh/id_ed25519 secret-name.age

# Rekey all secrets (after adding/removing keys in secrets.nix)
agenix -r
```

### Deployment Commands

#### Using deploy-rs (default)
```bash
# Deploy to a specific host
just deploy <hostname>

# Deploy with boot activation (for kernel/bootloader changes)
just boot <hostname>

# Build and push to cache
just build <hostname>
```

#### Using Colmena (alternative)
```bash
# Deploy to one or more hosts
just colmena-deploy <hostname1> <hostname2>

# Deploy with reboot
just colmena-boot <hostname>

# Build without deploying
just colmena-build <hostname>

# Interactive deployment (select hosts interactively)
just colmena-interactive

# Show all available hosts
just colmena-info
```

#### General Commands
```bash
# Format all Nix files
just fmt
```

### Available Hosts
- storage (main server)
- cloud (cloud server)
- router
- r2s (ARM-based router)
- raspi3 (Raspberry Pi 3)
- core, hpe, g14, raider, striker (various desktops/laptops)

## Architecture Overview

### Remote Builders
The repository is configured to use `cloud` (aarch64-linux) as a remote builder:
- When in `nix develop` shell, aarch64 packages are automatically built on cloud
- This avoids slow emulation when building from x86_64 machines
- CI environments don't use remote builders and build locally instead
- Configuration is in `nix-builders.conf`

### Directory Structure
- `/hosts/` - Machine-specific configurations. Each host has its own directory with configuration.nix and hardware-configuration.nix
- `/modules/` - Reusable NixOS modules, especially the `constellation/` modules that provide opt-in features
- `/secrets/` - Encrypted secrets using agenix (age encryption)
- `/home/` - Home Manager configuration for user environments

### Key Configuration Patterns

1. **Constellation Modules**: The repository uses a modular system where features are opt-in via constellation modules:
   - `constellation.common` - Base configuration
   - `constellation.backup` - Backup system
   - `constellation.services` - Service configurations
   - `constellation.media` - Media server stack
   - `constellation.podman` - Container runtime

2. **Secret Management**: All secrets are encrypted with agenix. Secrets are defined in `secrets/secrets.nix` and encrypted files are in `/secrets/*.age`

3. **Deployment**: Supports both deploy-rs and Colmena for remote deployment. All hosts are accessible via Tailscale VPN (*.bat-boa.ts.net)

## Important Notes

- All hosts use Tailscale networking for secure communication
- The repository uses Attic for binary caching to speed up builds
- Disk partitioning is declarative using disko
- Services often use Podman containers
- The storage host runs most services including media servers, databases, and backup systems

## Service and Network Details

- arsfeld.one is served through tailscale by storage if inside the tailnet, otherwise it's served through cloud

## Testing Changes

Before deploying:
1. Test build locally: `nix build .#nixosConfigurations.<hostname>.config.system.build.toplevel`
2. Format code: `just fmt`
3. Deploy to test system first if available
```