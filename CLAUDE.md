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
# Create a new secret (proper workflow):
# 1. Add entry to secrets/secrets.nix
# 2. Stage the secrets.nix change (DO NOT commit yet)
git add secrets/secrets.nix

# 3. Create the encrypted secret file
# Use --rules to point to secrets/secrets.nix when in repo root
openssl rand -base64 32 | nix develop -c ragenix --rules secrets/secrets.nix -e secret-name.age --editor -

# Edit an encrypted secret interactively
ragenix --rules secrets/secrets.nix -e secret-name.age

# Edit/update a secret programmatically (using stdin)
echo "new-secret-value" | ragenix --rules secrets/secrets.nix -e secret-name.age --editor -

# View decrypted secret (use with caution)
nix develop -c ragenix --rules secrets/secrets.nix -d secret-name.age

# Rekey all secrets (after adding/removing keys in secrets.nix)
ragenix --rules secrets/secrets.nix -r
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
- `/secrets/` - Encrypted secrets using ragenix (rust-based age encryption)
- `/home/` - Home Manager configuration for user environments

### Key Configuration Patterns

1. **Constellation Modules**: The repository uses a modular system where features are opt-in via constellation modules:
   - `constellation.common` - Base configuration
   - `constellation.backup` - Backup system
   - `constellation.services` - Service configurations
   - `constellation.media` - Media server stack
   - `constellation.podman` - Container runtime

2. **Secret Management**: All secrets are encrypted with ragenix. Secrets are defined in `secrets/secrets.nix` and encrypted files are in `/secrets/*.age`

3. **Deployment**: Supports both deploy-rs and Colmena for remote deployment. All hosts are accessible via Tailscale VPN (*.bat-boa.ts.net)

## Important Notes

- All hosts use Tailscale networking for secure communication
- The repository uses Attic for binary caching to speed up builds
- Disk partitioning is declarative using disko
- Services often use Podman containers
- The storage host runs most services including media servers, databases, and backup systems

## Service and Network Details

### Media Gateway Architecture

The repository uses a centralized gateway system for exposing services:

**Service Configuration Files:**

1. **`modules/constellation/services.nix`** - Central service registry
   - Add **native systemd services** here (e.g., Attic, duplicati, gitea)
   - Defines service ports for each host (cloud vs storage)
   - Controls authentication (`bypassAuth` list)
   - Controls public access (`funnels` list for Tailscale Funnel)
   - Controls Tailscale node creation (`tailscaleExposed` list)
   - This is the **primary place to add new services**

2. **`modules/constellation/media.nix`** - Container orchestration
   - Add **containerized services** here (e.g., Plex, Jellyfin, Overseerr)
   - Defines `storageServices` and `cloudServices` sections
   - Automatically adds host attribution to each service
   - Sets up volume mounts, environment variables, and container settings
   - Only for services running in containers, not native systemd services

3. **`modules/media/gateway.nix`** - Gateway implementation
   - Consumes service definitions from `media.gateway.services`
   - Generates Caddy reverse proxy configuration
   - Runs on **cloud** host and proxies to services on storage
   - Handles TLS certificates and error pages
   - Integrates with tsnsrv for Tailscale node management

**Service Access:**
- `*.arsfeld.one` domains use **split-horizon DNS** for optimal routing:
  - **Public access** (outside tailnet): Cloudflare → cloud (gateway) → storage
  - **Internal access** (inside tailnet): Tailscale MagicDNS → storage (direct, no cloud hop)
  - Both storage and cloud run Caddy with identical service configurations
  - This avoids unnecessary cloud roundtrips for internal network traffic
- `*.bat-boa.ts.net` domains (if in `tailscaleExposed`):
  - With `funnel = false`: Only accessible within the tailnet
  - With `funnel = true`: Publicly accessible via Tailscale Funnel

## Testing Changes

Before deploying:
1. Test build locally: `nix build .#nixosConfigurations.<hostname>.config.system.build.toplevel`
2. Format code: `just fmt`
3. Deploy to test system first if available

## Commit Message Format

**IMPORTANT**: All commits must follow conventional commit format.

### Format
```
<type>(<scope>): <subject>

[optional body]
```

### Types
- `feat`: New feature or functionality
- `fix`: Bug fix
- `chore`: Maintenance tasks (secrets, dependencies, etc.)
- `docs`: Documentation changes
- `refactor`: Code refactoring without changing behavior
- `test`: Adding or updating tests
- `ci`: CI/CD changes

### Scopes
Use the hostname or module being modified:
- `(raider)`, `(storage)`, `(cloud)` - Host-specific changes
- `(secrets)` - Secret management changes
- `(modules)` - Module changes
- `(home)` - Home Manager changes

### Examples
```bash
feat(raider): add Stash media organizer service
fix(storage): resolve bcachefs mount timeout issue
chore(secrets): add stash authentication secrets
docs(readme): update deployment instructions
```

### Rewriting Recent Commits
If commits don't follow the format:
```bash
# Soft reset to before the commits
git reset --soft HEAD~N

# Recommit with proper format
git add <files>
git commit -m "type(scope): subject"
```

## Adding New Services

When adding a new service:

1. **For native systemd services** (Attic, gitea, duplicati, etc.):
   - Add to `modules/constellation/services.nix` in the appropriate host section (cloud or storage)
   - Add to `bypassAuth` list if the service has its own authentication
   - Add to `tailscaleExposed` list if it needs a dedicated Tailscale node (creates `service.bat-boa.ts.net`)
   - Add to `funnels` list if `bat-boa.ts.net` should be publicly accessible (not just tailnet)
   - Note: All services are accessible via `service.arsfeld.one` through cloud gateway regardless of these settings
   - Deploy to **cloud** host to update the gateway configuration

2. **For containerized services** (Plex, Jellyfin, etc.):
   - Add to `modules/constellation/media.nix` in `storageServices` or `cloudServices`
   - Define image, ports, volumes, and environment variables
   - **Volume paths**:
     - `storageServices`: Can use `${vars.storageDir}` for large media files (defaults to `/mnt/storage` on storage host)
     - `cloudServices`: Should use `${vars.configDir}` (defaults to `/var/data`) or direct paths - **do NOT use storageDir** as cloud host doesn't have `/mnt/storage` mount
     - `storageDir` is only for large media files/downloads, not regular container config/data
   - The service will automatically be added to the gateway
```

<!-- BACKLOG.MD MCP GUIDELINES START -->

<CRITICAL_INSTRUCTION>

## BACKLOG WORKFLOW INSTRUCTIONS

This project uses Backlog.md MCP for all task and project management activities.

**CRITICAL RESOURCE**: Read `backlog://workflow/overview` to understand when and how to use Backlog for this project.

- **First time working here?** Read the overview resource IMMEDIATELY to learn the workflow
- **Already familiar?** You should have the overview cached ("## Backlog.md Overview (MCP)")
- **When to read it**: BEFORE creating tasks, or when you're unsure whether to track work

The overview resource contains:
- Decision framework for when to create tasks
- Search-first workflow to avoid duplicates
- Links to detailed guides for task creation, execution, and completion
- MCP tools reference

You MUST read the overview resource to understand the complete workflow. The information is NOT summarized here.

</CRITICAL_INSTRUCTION>

<!-- BACKLOG.MD MCP GUIDELINES END -->
