# NixOS Configuration

[![NixOS 25.11](https://img.shields.io/badge/NixOS-25.11-blue.svg)](https://nixos.org)
[![Flakes](https://img.shields.io/badge/Flakes-Enabled-blue.svg)](https://nixos.wiki/wiki/Flakes)
[![Build](https://github.com/arsfeld/nixos/actions/workflows/build.yml/badge.svg)](https://github.com/arsfeld/nixos/actions/workflows/build.yml)

Personal NixOS configuration managing multiple machines using Nix Flakes and [flake-parts](https://flake.parts/).

## Systems

### Infrastructure
| Host | Role | Hardware | Status |
|------|------|----------|--------|
| **galactica** | Main server (media, databases, backups) | Intel i5-1340P, 12c/16t, 32GB, ~45TB | Online |
| **basestar** | Public-facing services (`*.arsfeld.dev`) | ARM Neoverse-N1, 4c, 24GB (Oracle Cloud) | Online |
| **router** | Network router | Intel N5105, 4c, 8GB | Offline |
| **r2s** | Backup router + home automation | Rockchip RK3328 ARM, 4c, 1GB | Offline |
| **pegasus** | Secondary server | Intel i5-4430, 4c, 16GB, ~18TB | Online |

### Embedded
| Host | Role | Status |
|------|------|--------|
| **octopi** | OctoPrint | Offline |
| **raspi3** | Raspberry Pi 3 | Offline |
| **cylon-link** | Valve Steam Link, always-on helper | Online |

### Desktops & Laptops
| Host | Role | Hardware | Status |
|------|------|----------|--------|
| **raider** | Desktop (GNOME, gaming, dev) | i5-12500H, RX 6650 XT, 32GB, ~4TB | Online |
| **blackbird** | ASUS ROG Zephyrus G14 laptop | - | Active |

See [HARDWARE.md](HARDWARE.md) for detailed disk and CPU specs.

### Tiers

Hosts are grouped into deployment tiers (each host's `tier` in `modules/hosts/<name>.nix`, collected into the `tiers` flake output):

| Tier | Hosts | Meaning |
|------|-------|---------|
| **tier1** | galactica, basestar, raider | Always on, should always be deployed |

Tiers are exposed as `@tier` selectors, so you can deploy a whole tier at once:

```bash
just deploy @tier1     # deploy all tier-1 hosts
```

## Features

- **Modular Architecture** - Opt-in features for services, media, backups, observability, and more, imported per host
- **Auto-Discovery** - Every file under `modules/` loaded automatically via [import-tree](https://github.com/vic/import-tree) (the dendritic pattern)
- **Service Registry** - Centralized port assignments, auth bypass, Tailscale exposure, and CORS config
- **Container Orchestration** - Podman/Docker-based media stack with declarative volume and network config
- **DNS & Routing** - `*.arsfeld.one` (internal via cloudflared), `*.arsfeld.dev` (public), `*.bat-boa.ts.net` (Tailscale)
- **Automated Deployments** - Two-phase nix-fast-build pipeline (parallel eval, build, niks3 push, then parallel activation), nixos-rebuild fallback
- **Secret Management** - sops-nix with per-host and shared secrets
- **Binary Caching** - niks3 coordinator with a Cloudflare R2 read path (`cache.arsfeld.dev`)
- **Infrastructure as Code** - Oracle Cloud tenancy and Cloudflare DNS zones managed via OpenTofu, written in Nix with terranix (see [CLAUDE.md](CLAUDE.md))
- **Remote Builders** - aarch64 builds via basestar host
- **Declarative Everything** - Including disk partitioning (disko)
- **CI/CD** - GitHub Actions builds all hosts, pushes to niks3, weekly flake updates

## Cylon Bot

A Waveshare ESP32-S3 AMOLED 1.75C (round 466×466 touch screen, speaker, microphone) that
sits on the desk and shows every Claude Code session across the fleet.

```
hooks on every host --HTTPS--> cylon-bot-bridge (galactica) <--wss-- board (firmware/cylon-bot)
```

- **Session board** - Home is a Cylon Centurion head inside a ring of arcs, one per session,
  coloured by state. Tap through to a session's live feed of prompts, tool calls and replies.
- **Answering from the desk** - Claude's multiple-choice questions take over the screen and
  are answered with a tap. Tool approvals can optionally be allowed or denied from the board too.
  No board, no answer or a timeout fall through to the normal terminal prompt.
- **Voice** - Hold the avatar to talk. Speech is transcribed by whisper.cpp, answered by a
  persistent Hermes assistant, and spoken back through Piper with a Centurion voice effect.
  The assistant can set timers, report the weather and control exposed Home Assistant devices.
- **Commands** - Swipe down from the top for volume, link status and a purge of the
  conversation's memory.

| Part | Where |
|------|-------|
| Hooks (`cylon-bot-hook`, installed by home-manager) | `packages/cylon-bot-hook` |
| Bridge (Rust, axum) and its voice services | `packages/cylon-bot-bridge`, `modules/hosts/galactica/services/cylon-bot*.nix` |
| Shared wire types and board model | `packages/cylon-bot-proto` |
| Firmware (Rust, `esp-idf-svc`, Slint) | `firmware/cylon-bot` |

```bash
just board backup    # save the full flash first
just board creds     # write credentials from sops
just board build
just board flash
just board monitor
just board preview   # render every screen to PNG, no board needed
```

Details, traps and deploy order are in [CLAUDE.md](CLAUDE.md#cylon-bot-esp32-session-board) and
the specs under `docs/superpowers/specs/`.

## Quick Start

```bash
# Enter development shell
nix develop

# Deploy to one or more hosts
just deploy galactica
just deploy galactica basestar

# Build locally without deploying
just build <hostname>

# Fresh install on new hardware
just install <hostname> <target-ip>

# Format all Nix files
just fmt

# Plan/apply the Oracle Cloud + Cloudflare DNS infrastructure
just tf plan
just tf apply
```

## Project Structure

```
flake.nix              # Flake entry point (nixpkgs-26.05, flake-parts, import-tree ./modules)
modules/               # Every .nix file is a flake-parts module (paths with /_ excepted)
  flake/               #   Flake plumbing
    lib.nix            #     mkLinuxSystem, overlays, baseModules
    hosts.nix          #     configurations.nixos option -> nixosConfigurations, tiers, ciMatrix
    deploy.nix         #     deployTargets: per-host system closures
    dev.nix            #     Development shell, formatter, git hooks
    checks.nix         #     Flake checks (NixOS VM tests and others)
    images.nix         #     SD card, kexec, and installer ISO images
    infra.nix          #     OpenTofu config (terranix) and pinned tofu
    systems.nix        #     Supported systems, flake.modules option
    nixos-modules.nix  #     Exports the features as nixosModules
  base/                #   The base feature, added to every host
  hosts/               #   One <name>.nix declaration plus a <name>/ directory per host
  media/               #   Media stack (config, gateway, containers, services)
  backup/ desktop/ ... #   Other features, flake.modules.nixos.<feature>
home/                  # Home Manager configurations
packages/              # Custom Nix derivations (packages/<name>/package.nix)
firmware/cylon-bot/    # ESP32 session board firmware (Rust + Slint)
secrets/               # Encrypted secrets (sops/*.yaml)
```

## Features

Hosts compose their configuration by importing features in their declaration,
`modules/hosts/<name>.nix` (`module.imports = [features.podman …]`). `base`
(common settings, users, sops, email, Tailscale, SSH) is added to every host.

| Feature | Purpose |
|---------|---------|
| `base` | Base config: Nix settings, caches, SSH, Tailscale, users, sops, email |
| `media` | Media stack: `media.services`, gateway, containers |
| `podman` | Container runtime |
| `tsnsrv` | Tailscale service nodes |
| `backrest` (+ `backup-notify`, `backup-status`) / `backup-summary` | Backups via Backrest; weekly summary |
| `desktop` (+ `pantheon-dock`, `pantheon-gamemode`) | Desktop environments (GNOME, Pantheon, …) |
| `gaming` | Gaming environment (Steam, etc.) |
| `development` | Dev tools (Docker, Node, Python, Go, Rust) |
| `virtualization` | KVM/libvirt VMs |
| `netdata-client` | Netdata agent |
| `forgejo-runner` | Forgejo Actions runner |
| `check-stock` / `blocky` | Stock checker; Blocky DNS (unused) |

Code only one host uses (home-assistant, vpn-exit-nodes, media-sync,
project-vms, …) lives in that host's `modules/hosts/<name>/` directory.

## Tooling

- [Nix Flakes](https://nixos.wiki/wiki/Flakes) + [flake-parts](https://flake.parts/) - Reproducible, modular configurations
- [nix-fast-build](https://github.com/Mic92/nix-fast-build) - Parallel evaluation and build for deploys
- [Home Manager](https://github.com/nix-community/home-manager) - User environment management
- [sops-nix](https://github.com/Mic92/sops-nix) - Secret management
- [disko](https://github.com/nix-community/disko) - Declarative disk partitioning
- [import-tree](https://github.com/vic/import-tree) - Loads every file under `modules/` as a flake-parts module
- [niks3](https://github.com/Mic92/niks3) - S3-backed binary cache with reference-tracking GC
- [Tailscale](https://tailscale.com/) - VPN mesh network
- [OpenTofu](https://opentofu.org/) + [terranix](https://terranix.org/) - Oracle Cloud and Cloudflare DNS as Nix code

## Documentation

- [CLAUDE.md](CLAUDE.md) - Development and deployment instructions
- [HARDWARE.md](HARDWARE.md) - Hardware inventory and specs

## License

Personal use. Feel free to take inspiration for your own configurations.
