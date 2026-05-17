# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Overview

This is a personal NixOS configuration repository that manages multiple machines using Nix Flakes and flake-parts. It includes configurations for servers (storage, basestar), embedded devices (R2S, Raspberry Pi), and desktop systems (raider, blackbird).

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
just deploy storage basestar   # Deploy to multiple hosts in parallel
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
nix develop -c sops --decrypt secrets/sops/basestar.yaml  # View decrypted
nix develop -c sops updatekeys secrets/sops/<file>.yaml  # Re-encrypt after key changes
```

Configured via `.sops.yaml`. All hosts use `constellation.sops.enable = true`. Use standard `sops.secrets` options. Common/shared secrets: `config.constellation.sops.commonSopsFile`.

### Available Hosts
- **storage** - Main server: media services, databases, backups. Hosts internal services on `*.arsfeld.one` via cloudflared tunnel (wildcard ingress)
- **basestar** - Public-facing server (BSG Cylon Basestar): hosts services on `*.arsfeld.dev` (blog, plausible, planka, siyuan, supabase)
- **raider** - Desktop workstation: GNOME, gaming, development
- **router** - Custom network device (no constellation modules, standalone config)
- **r2s** - ARM-based router (NanoPi R2S)
- **raspi3** - Raspberry Pi 3
- **blackbird** - ASUS ROG Zephyrus G14 laptop (BSG Blackbird — custom stealth ship)
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
- `storageDir` = `/mnt/storage` - Large media files (**storage host only**, not available on basestar)
- `dataDir` = `/mnt/storage` - Primary data directory
- `puid`/`pgid` = `5000` - UID/GID for all media services
- `user`/`group` = `"media"` - Service user
- `domain` = `"arsfeld.one"` - Primary domain
- `tsDomain` = `"bat-boa.ts.net"` - Tailscale domain

### Service and Network Architecture

#### `mkService` is the only way to declare a service
All service declarations on storage/basestar go through the `mkService` helper at `modules/media/__mkService.nix`. It writes to `media.containers.<name>` for containers (which auto-populates `media.gateway.services.<name>`) or directly to `media.gateway.services.<name>` for native/gateway-only services. Do **not** write to `virtualisation.oci-containers.containers` or to `media.gateway.services` by hand — those are implementation details and bypassing `mkService` will silently miss the standardized PUID/PGID/TZ env, the auto-tmpfiles config dir, the gateway entry, and image-watching.

```nix
let mkService = import "${self}/modules/media/__mkService.nix" {inherit lib;};
in lib.mkMerge [
  (mkService "myapp" {
    port = 8080;                    # required for containers; optional for gateway-only (auto-assigned)
    image = "ghcr.io/.../myapp";    # defaults to ghcr.io/linuxserver/<name>
    bypassAuth = true;              # skip Authelia
    tailscaleExposed = true;        # creates a *.bat-boa.ts.net node via tsnsrv
    cors = true;                    # enable CORS
    funnel = true;                  # public via Tailscale Funnel
    insecureTls = true;             # backend has self-signed cert
    host = "192.168.15.1";          # gateway-host override (e.g. VPN namespace IP)
    container = {                   # omit for gateway-only services
      exposePort = 38080;           # host port (defaults to nameToPort <name>)
      mediaVolumes = true;          # mount /media + /files
      configDir = "/config";        # default; set null to skip the auto config-dir mount
      cmd = ["worker" "run"];       # container command
      devices = ["/dev/dri:/dev/dri"];
      network = "ai";               # podman network
      environment = { FOO = "bar"; };
      environmentFiles = [config.sops.secrets.foo.path];
      volumes = ["/host:/container"];
      extraOptions = ["--add-host=host.containers.internal:host-gateway"];
    };
    watchImage = true;              # poll registry & restart on new image
  })
]
```

The mkService settings (`bypassAuth`, `cors`, `funnel`, `insecureTls`) are forwarded to `media.gateway.services.<name>.settings`. `tailscaleExposed` and `host` are caller-only and don't have container equivalents.

For containers without a gateway entry (e.g. headscale-ui, qdrant), set `container.extraOptions = ["--publish=HOST:CONTAINER"]` and leave `port = null`. mkService then registers the container without auto-creating a gateway service.

#### Container Module (`modules/media/containers.nix`)
Backs `media.containers.*`. Auto-creates the matching `media.gateway.services.<name>` entry when `listenPort != null`, mounts `${configDir}/<name>:<container.configDir>`, sets PUID/PGID/TZ from `media.config`, and wires image-watching when `watchImage = true`.

**Volume path rules:**
- Use `${vars.storageDir}` for media, `${vars.configDir}` for config

#### Gateway (`modules/media/gateway.nix`)
Caddy reverse proxy consuming service definitions. Generates TLS configs, error pages, tsnsrv integration.

#### DNS & Routing
- `*.arsfeld.one` — internal services hosted on **storage**, routed via Cloudflare → storage's cloudflared tunnel (wildcard ingress)
- `*.arsfeld.dev` — public services hosted on **basestar** (blog, plausible, planka, siyuan, supabase)
- `*.bat-boa.ts.net` — Tailscale-only access (or public via Funnel)

### Remote Builders
`basestar` (aarch64-linux) serves as remote builder. When in `nix develop`, aarch64 packages build on basestar automatically via `nix-builders.conf`.

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

Always declare services with `mkService` (see "Service and Network Architecture" above). The pattern below applies to both containers and native NixOS services — only the `container` attr differs.

### `*.arsfeld.one` services (on storage)
1. Create a service file in `hosts/storage/services/` and add it to `default.nix` imports.
2. Wrap the file body in `lib.mkMerge` and call `mkService "<name>" { … }` for the gateway/container declaration.
3. Storage's wildcard cloudflared tunnel routes traffic automatically; the gateway entry is created by `mkService`.

### `*.arsfeld.dev` services (on basestar)
1. Create a service file in `hosts/basestar/services/` and add it to `default.nix` imports.
2. Use `mkService` the same way; basestar uses dedicated Caddy vhosts for `arsfeld.dev` subdomains.

## Commit Message Format

Conventional commits required: `<type>(<scope>): <subject>`

**Types**: `feat`, `fix`, `chore`, `docs`, `refactor`, `test`, `ci`
**Scopes**: hostname (`raider`, `storage`, `basestar`), or `secrets`, `modules`, `home`

Never mention Claude in commit messages or author.

## CI/CD (.github/workflows/)

- **build.yml** - Builds basestar (aarch64), storage (x86_64), raider (x86_64) closures and pushes to Attic cache
- **format.yml** - Checks formatting with alejandra (fails if unformatted, run `just fmt` locally)
- **update.yml** - Weekly flake input updates with automatic build testing, commits flake.lock if all hosts build
