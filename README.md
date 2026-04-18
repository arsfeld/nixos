# NixOS Configuration

[![NixOS 25.11](https://img.shields.io/badge/NixOS-25.11-blue.svg)](https://nixos.org)
[![Flakes](https://img.shields.io/badge/Flakes-Enabled-blue.svg)](https://nixos.wiki/wiki/Flakes)
[![Build](https://github.com/arsfeld/nixos/actions/workflows/build.yml/badge.svg)](https://github.com/arsfeld/nixos/actions/workflows/build.yml)

Personal NixOS configuration managing multiple machines using Nix Flakes and [flake-parts](https://flake.parts/).

## Systems

### Infrastructure
| Host | Role | Hardware | Status |
|------|------|----------|--------|
| **storage** | Main server (media, databases, backups, k3s) | Intel i5-1340P, 12c/16t, 32GB, ~45TB | Online |
| **basestar** | Public-facing services (`*.arsfeld.dev`) | ARM Neoverse-N1, 4c, 24GB (Oracle Cloud) | Online |
| **router** | Network router | Intel N5105, 4c, 8GB | Offline |
| **r2s** | Backup router + home automation | Rockchip RK3328 ARM, 4c, 1GB | Offline |
| **pegasus** | Secondary server | - | Offline |

### Embedded
| Host | Role | Status |
|------|------|--------|
| **octopi** | OctoPrint | Offline |
| **raspi3** | Raspberry Pi 3 | Offline |

### Desktops & Laptops
| Host | Role | Hardware | Status |
|------|------|----------|--------|
| **raider** | Desktop (GNOME, gaming, dev) | i5-12500H, RX 6650 XT, 32GB, ~4TB | Online |
| **blackbird** | ASUS ROG Zephyrus G14 laptop | - | Active |

See [HARDWARE.md](HARDWARE.md) for detailed disk and CPU specs.

## Features

- **Modular Architecture** - Opt-in constellation modules for services, media, backups, observability, and more
- **Auto-Discovery** - Hosts and modules loaded automatically via [haumea](https://github.com/nix-community/haumea)
- **Service Registry** - Centralized port assignments, auth bypass, Tailscale exposure, and CORS config
- **Container Orchestration** - Podman/Docker-based media stack with declarative volume and network config
- **DNS & Routing** - `*.arsfeld.one` (internal via cloudflared), `*.arsfeld.dev` (public), `*.bat-boa.ts.net` (Tailscale)
- **Automated Deployments** - Colmena (primary) with aarch64 cross-compilation, nixos-rebuild fallback
- **Secret Management** - sops-nix with per-host and shared secrets
- **Binary Caching** - Attic server for faster builds
- **Remote Builders** - aarch64 builds via basestar host
- **Declarative Everything** - Including disk partitioning (disko)
- **CI/CD** - GitHub Actions builds all hosts, pushes to Attic cache, weekly flake updates

## Quick Start

```bash
# Enter development shell
nix develop

# Deploy to one or more hosts
just deploy storage
just deploy storage basestar

# Build locally without deploying
just build <hostname>

# Fresh install on new hardware
just install <hostname> <target-ip>

# Format all Nix files
just fmt
```

## Project Structure

```
flake.nix              # Flake entry point (nixpkgs-25.11, flake-parts)
flake-modules/         # Flake-parts modules
  lib.nix              #   Core utilities, haumea loaders, overlays
  hosts.nix            #   Auto-discovers hosts from hosts/ directories
  colmena.nix          #   Colmena deployment config
  deploy.nix           #   deploy-rs config (currently broken with Nix 2.32+)
  dev.nix              #   Development shell
  checks.nix           #   Pre-commit hooks, formatter
  images.nix           #   SD card, kexec, and installer ISO images
hosts/                 # Per-host configurations (auto-discovered)
modules/               # All NixOS modules (auto-loaded by haumea)
  constellation/       #   Opt-in feature modules
  services/            #   Service group modules (media, home apps, network)
  media/               #   Media stack (config, gateway, components)
home/                  # Home Manager configurations
packages/              # Custom Nix derivations (auto-loaded by haumea)
secrets/               # Encrypted secrets (sops/*.yaml)
```

## Constellation Modules

Hosts compose their configuration by enabling modules via `constellation.<module>.enable = true`:

| Module | Purpose |
|--------|---------|
| `common` | Base config: Nix settings, caches, SSH, Tailscale, Avahi |
| `users` | User accounts, SSH keys, sudo |
| `sops` | sops-nix secret management |
| `docker` / `podman` | Container runtimes |
| `backup` | Automated rustic/restic backups |
| `gnome` / `cosmic` / `niri` | Desktop environments |
| `gaming` | Gaming environment (Steam, etc.) |
| `development` | Dev tools (Docker, Node, Python, Go, Rust) |
| `virtualization` / `project-vms` | KVM/libvirt VMs |
| `home-assistant` | Home automation |
| `vpn-exit-nodes` | Tailscale exit nodes via AirVPN/Gluetun |
| `observability-hub` | Central Prometheus/Loki hub |
| `metrics-client` / `logs-client` / `netdata-client` | Observability agents |
| `media-sync` / `tablet-sync` | File synchronization |
| `opencloud` / `email` | Cloud storage, email |

## Tooling

- [Nix Flakes](https://nixos.wiki/wiki/Flakes) + [flake-parts](https://flake.parts/) - Reproducible, modular configurations
- [Colmena](https://colmena.cli.rs/) - Primary deployment tool (parallel, cross-compilation)
- [Home Manager](https://github.com/nix-community/home-manager) - User environment management
- [sops-nix](https://github.com/Mic92/sops-nix) - Secret management
- [disko](https://github.com/nix-community/disko) - Declarative disk partitioning
- [haumea](https://github.com/nix-community/haumea) - Automatic module/package discovery
- [Attic](https://github.com/zhaofengli/attic) - Binary cache
- [Tailscale](https://tailscale.com/) - VPN mesh network

## Documentation

- [CLAUDE.md](CLAUDE.md) - Development and deployment instructions
- [HARDWARE.md](HARDWARE.md) - Hardware inventory and specs

## License

Personal use. Feel free to take inspiration for your own configurations.
