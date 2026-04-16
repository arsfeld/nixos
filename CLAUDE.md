# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Overview

This is a personal NixOS configuration repository that manages multiple machines using Nix Flakes and flake-parts. It includes configurations for servers (storage, cloud), embedded devices (R2S, Raspberry Pi), and desktop systems (raider, g14).

## Key Commands

### Development Environment
```bash
nix develop                    # Enter dev shell (required for most operations)
just fmt                       # Format all Nix files with alejandra
just build <hostname>          # Build a host config locally
```

### Deployment (via Colmena, default)
```bash
just deploy storage            # Deploy to one host
just deploy storage cloud      # Deploy to multiple hosts in parallel
just boot storage              # Boot activation (next reboot)
just test storage              # Test without activating
just deploy-all                # Deploy to all hosts
just reboot storage            # Deploy and reboot (kernel changes)
just info                      # List all known hosts
```

nixos-rebuild fallback: `just nr-deploy <host>`, `just nr-boot <host>`, `just nr-test <host>`

deploy-rs is available but currently broken with Nix 2.32+ (`just deploy-rs`, `just boot-rs`).

All hosts are reached via Tailscale: `<hostname>.bat-boa.ts.net`.

### Testing Changes
```bash
nix build .#nixosConfigurations.<hostname>.config.system.build.toplevel
```

### Secret Management

```bash
nix develop -c sops secrets/sops/<hostname>.yaml    # Create/edit host secrets
nix develop -c sops --decrypt secrets/sops/cloud.yaml  # View decrypted
nix develop -c sops updatekeys secrets/sops/<file>.yaml  # Re-encrypt after key changes
```

Configured via `.sops.yaml`. All hosts use `constellation.sops.enable = true`. Use standard `sops.secrets` options. Common/shared secrets: `config.constellation.sops.commonSopsFile`.

### Available Hosts
- **storage** - Main server: media services, databases, backups, k3s server. Hosts internal services on `*.arsfeld.one` via cloudflared tunnel (wildcard ingress)
- **cloud** - Cloud server: hosts public-facing services on `*.arsfeld.dev` (blog, plausible, planka, siyuan, supabase)
- **raider** - Desktop workstation: GNOME, gaming, development
- **router** - Custom network device (no constellation modules, standalone config)
- **r2s** - ARM-based router (NanoPi R2S)
- **raspi3** - Raspberry Pi 3
- **g14** - ASUS ROG Zephyrus G14 laptop
- **pegasus** - Secondary server (BSG Battlestar Pegasus)
- **octopi** - OctoPrint device

For hardware specs (CPU, RAM, disks), see [HARDWARE.md](HARDWARE.md).

## Architecture Overview

### Flake Structure

The flake uses **flake-parts** to organize outputs into modules under `flake-modules/`:
- **`lib.nix`** - Core utilities: `mkLinuxSystem`, overlays, `baseModules`, `homeManagerModules`. Uses **haumea** to recursively auto-load all files from `modules/` and `packages/` directories.
- **`hosts.nix`** - Auto-discovers hosts by scanning `hosts/` for directories with `configuration.nix`. Automatically includes `disko-config.nix` if present.
- **`deploy.nix`** - deploy-rs configuration for each host
- **`colmena.nix`** - Colmena deployment with cross-compilation support for aarch64
- **`dev.nix`** - Development shell, formatter, git hooks, custom packages
- **`checks.nix`** - Flake checks (router NixOS test)
- **`images.nix`** - System image generators (SD cards, kexec)

### Module Auto-Discovery

All `.nix` files under `modules/` are loaded automatically by haumea - no explicit imports needed. To add a new module, create a file in `modules/` (or a subdirectory) and it will be available to all hosts. Hosts then selectively enable modules via `constellation.<module>.enable = true`.

### Constellation Modules (`modules/constellation/`)

Opt-in feature modules that hosts compose. Key modules:

| Module | Purpose |
|--------|---------|
| `common.nix` | Base config: Nix flakes, caches, SSH, Tailscale, Avahi |
| `users.nix` | User accounts, SSH keys, sudo |
| `sops.nix` | sops-nix infrastructure (age keys, default paths) |
| `services.nix` | **Central service registry**: ports, auth, CORS, Tailscale exposure |
| `media.nix` | **Container orchestration**: Plex, *arr, Stash, Nextcloud, etc. |
| `podman.nix` / `docker.nix` | Container runtimes |
| `backup.nix` | Automated rustic/restic backups |
| `k3s.nix` | Kubernetes cluster (server/agent roles) |
| `vpn-exit-nodes.nix` | Tailscale exit nodes via AirVPN/Gluetun |
| `gnome.nix` / `cosmic.nix` / `niri.nix` | Desktop environments |
| `development.nix` | Dev tools (Docker, Node, Python, Go, Rust) |
| `gaming.nix` | Gaming environment |
| `metrics-client.nix` / `logs-client.nix` | Observability agents |
| `observability-hub.nix` | Central Prometheus/Loki hub |
| `home-assistant.nix` | Home automation |
| `virtualization.nix` / `project-vms.nix` | KVM/libvirt VMs |

### Media Configuration Variables (`modules/media/config.nix`)

Shared variables consumed by media services via `config.media.config`:
- `configDir` = `/var/data` - Service config/data directory
- `storageDir` = `/mnt/storage` - Large media files (**storage host only**, not available on cloud)
- `dataDir` = `/mnt/storage` - Primary data directory
- `puid`/`pgid` = `5000` - UID/GID for all media services
- `user`/`group` = `"media"` - Service user
- `domain` = `"arsfeld.one"` - Primary domain
- `tsDomain` = `"bat-boa.ts.net"` - Tailscale domain

### Service and Network Architecture

#### Service Registry (`modules/constellation/services.nix`)
Central source of truth for all service metadata. Controls:
- Port assignments per host (cloud vs storage)
- `bypassAuth` - Services with own auth (skip Authelia)
- `tailscaleExposed` - Services with dedicated `*.bat-boa.ts.net` nodes
- `funnels` - Public Tailscale Funnel services
- `cors` - CORS-enabled services

#### Container Orchestration (`modules/constellation/media.nix`)
Defines containerized services in `storageServices` section. Each service gets container image, ports, volumes, env vars. Uses `media.config` variables for paths.

**Volume path rules:**
- Use `${vars.storageDir}` for media, `${vars.configDir}` for config

#### Gateway (`modules/media/gateway.nix`)
Caddy reverse proxy consuming service definitions. Generates TLS configs, error pages, tsnsrv integration.

#### DNS & Routing
- `*.arsfeld.one` — internal services hosted on **storage**, routed via Cloudflare → storage's cloudflared tunnel (wildcard ingress)
- `*.arsfeld.dev` — public services hosted on **cloud** (blog, plausible, planka, siyuan, supabase)
- `*.bat-boa.ts.net` — Tailscale-only access (or public via Funnel)

### Remote Builders
`cloud` (aarch64-linux) serves as remote builder. When in `nix develop`, aarch64 packages build on cloud automatically via `nix-builders.conf`.

### Directory Structure
- `hosts/` - Per-machine configs (auto-discovered by `flake-modules/hosts.nix`)
- `modules/` - All NixOS modules (auto-loaded by haumea)
  - `constellation/` - Opt-in feature modules
  - `media/` - Media stack (config, gateway, components)
- `packages/` - Custom Nix derivations (auto-loaded by haumea)
- `home/` - Home Manager config (`home.nix` for user `arosenfeld`)
- `secrets/` - Encrypted secrets (`sops/*.yaml` managed by sops-nix)
- `flake-modules/` - Flake-parts modules
- `just/` - Justfile submodules (blog, secrets, docs)

## Adding New Services

### `*.arsfeld.one` services (on storage)
1. Create a service file in `hosts/storage/services/` and add to `default.nix` imports
2. Register in `media.gateway.services` with port, auth, and Tailscale exposure settings
3. Storage's wildcard cloudflared tunnel routes traffic automatically

### `*.arsfeld.dev` services (on cloud)
1. Create a service file in `hosts/cloud/services/` and add to `default.nix` imports
2. Cloud uses dedicated Caddy vhosts for `arsfeld.dev` subdomains

### Containerized services (on storage)
1. Add to `modules/constellation/media.nix` in `storageServices`
2. Define image, ports, volumes, environment variables
3. Service is automatically added to the gateway

## Commit Message Format

Conventional commits required: `<type>(<scope>): <subject>`

**Types**: `feat`, `fix`, `chore`, `docs`, `refactor`, `test`, `ci`
**Scopes**: hostname (`raider`, `storage`, `cloud`), or `secrets`, `modules`, `home`

Never mention Claude in commit messages or author.

## CI/CD (.github/workflows/)

- **build.yml** - Builds cloud (aarch64), storage (x86_64), raider (x86_64) closures and pushes to Attic cache
- **format.yml** - Checks formatting with alejandra (fails if unformatted, run `just fmt` locally)
- **update.yml** - Weekly flake input updates with automatic build testing, commits flake.lock if all hosts build

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
