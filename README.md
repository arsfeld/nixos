# NixOS Configuration

[![NixOS](https://img.shields.io/badge/NixOS-Unstable-blue.svg)](https://nixos.org)
[![Flakes](https://img.shields.io/badge/Flakes-Enabled-blue.svg)](https://nixos.wiki/wiki/Flakes)
[![Build](https://github.com/arsfeld/nixos/actions/workflows/build.yml/badge.svg)](https://github.com/arsfeld/nixos/actions/workflows/build.yml)

Personal NixOS configuration managing multiple machines using Nix Flakes.

## 💻 Systems

### 🏗️ Infrastructure
- 💾 **storage** - NAS server (Intel 13th gen, 12c/24t, 32GB, ~500GB) - media services and backups
- ☁️ **cloud** - Gateway proxy (ARM Neoverse, 4c, 24GB) - public services reverse proxy
- 🏡 **cottage** - Secondary server with ZFS storage *(offline)*
- 📧 **micro** - Mail server running mox *(offline)*
- 🔀 **router** - Network router (Intel N5105, 4c, 8GB)
- 🏠 **r2s** - Backup router + home automation (Rockchip RK3328 ARM, 4c, 1GB) - Home Assistant

### 🔌 Embedded
- 🖨️ **octopi** - Raspberry Pi running OctoPrint *(offline)*
- 🍓 **raspi3** - Raspberry Pi 3 *(offline)*

### ☁️ Cloud
- 🌐 **cloud-br** - Oracle Cloud ARM instance *(offline)*
- 🖥️ **core** - Minimal server instance *(offline)*
- 🏢 **hpe** - HPE server for virtualization *(offline)*

### 🖥️ Desktops & Laptops
- 🎮 **raider** - ITX desktop (ERYING G660, i5-12500H 12c/24t, RX 6650 XT, 32GB, 500GB+2TB NVMe)
- 💻 **g14** - ASUS ROG Zephyrus G14 laptop *(offline)*
- 🎯 **striker** - Gaming desktop *(offline)*

## ✨ Features

- 🧩 **Modular Architecture** - Opt-in constellation modules for services, media, backups, and more
- 🌍 **Split-Horizon DNS** - Optimized routing for internal vs. external access
- 🚀 **Automated Deployments** - Using deploy-rs and Colmena
- 🔐 **Secret Management** - Migrating from ragenix to sops-nix
- 📦 **Binary Caching** - Attic server for faster builds
- 🔨 **Remote Builders** - Automatic aarch64 builds via cloud host
- 📝 **Declarative Everything** - Including disk partitioning (disko)

## 🚀 Quick Start

```bash
# Enter development shell
nix develop

# Deploy to a host
just deploy <hostname>

# Fresh install on new hardware
just install <hostname> <target-ip>
```

## 📁 Project Structure

```
hosts/              # Host-specific configurations
modules/            # Reusable NixOS modules
  constellation/    # Modular opt-in features
  media/           # Media services
home/              # Home Manager configurations
packages/          # Custom packages
secrets/           # Encrypted secrets
```

## 🔧 Tooling

- [Nix Flakes](https://nixos.wiki/wiki/Flakes) - Reproducible configurations
- [Home Manager](https://github.com/nix-community/home-manager) - User environments
- [deploy-rs](https://github.com/serokell/deploy-rs) - Deployment automation
- [Colmena](https://colmena.cli.rs/) - Alternative deployment tool
- [sops-nix](https://github.com/Mic92/sops-nix) - Secret management
- [disko](https://github.com/nix-community/disko) - Declarative partitioning
- [Attic](https://github.com/zhaofengli/attic) - Binary cache
- [Tailscale](https://tailscale.com/) - VPN mesh network

## 📚 Documentation

See [CLAUDE.md](CLAUDE.md) for detailed development and deployment instructions.

## 📄 License

Personal use. Feel free to take inspiration for your own configurations.
