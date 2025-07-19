# 🚀 My NixOS Configuration

<!-- System -->
[![NixOS](https://img.shields.io/badge/NixOS-Unstable-blue.svg)](https://nixos.org)
[![Flakes](https://img.shields.io/badge/Flakes-Enabled-blue.svg)](https://nixos.wiki/wiki/Flakes)
[![Home Manager](https://img.shields.io/badge/Home%20Manager-Enabled-blue.svg)](https://github.com/nix-community/home-manager)
[![deploy-rs](https://img.shields.io/badge/deploy--rs-Enabled-blue.svg)](https://github.com/serokell/deploy-rs)

<!-- Status -->
[![Build](https://github.com/arsfeld/nixos/actions/workflows/build.yml/badge.svg)](https://github.com/arsfeld/nixos/actions/workflows/build.yml)
[![Last Commit](https://img.shields.io/github/last-commit/arsfeld/nixos)](https://github.com/arsfeld/nixos/commits/main)

<!-- Repository Info -->
[![License](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![Repo Size](https://img.shields.io/github/repo-size/arsfeld/nixos)](https://github.com/arsfeld/nixos)
[![Systems](https://img.shields.io/badge/Systems-7-blue.svg)](https://github.com/arsfeld/nixos#-whats-inside)

Welcome to my personal NixOS configuration repo! This is where I manage all my NixOS systems using the power of Nix flakes. ✨

## 🖥️ What's Inside

This repo contains configurations for multiple machines:

- 💾 **storage** - NAS/Storage server
- ☁️ **cloud** - Cloud server
- ☁️ **cloud-br** - Another cloud instance
- 🔄 **r2s** - Rockchip R2S device
- 🍓 **raspi3** - Raspberry Pi 3
- 🔌 **core** - Core infrastructure
- 🏢 **hpe** - HPE server

## 🛠️ Features

- 📦 Fully declarative system configurations
- 🏠 Home-manager setup for user environment
- 🔒 Secret management with Agenix
- 🔄 Deployment via deploy-rs
- 💻 Development environment with devshell
- 🤖 CI/CD pipeline for building systems
- 📊 Structured modular design

## 🚀 Usage

### Development

```bash
# Enter the development shell
nix develop
```

### Deployment

This repository uses [just](https://github.com/casey/just) as a task runner for common operations. Here are the main deployment commands:

#### Remote Installation with nixos-anywhere

For fresh installations on new hardware using [nixos-anywhere](https://github.com/nix-community/nixos-anywhere) and [disko](https://github.com/nix-community/disko):

```bash
# Install NixOS on a target machine (requires NixOS installer ISO booted)
just install <hostname> <target-ip>

# Example: Install router configuration
just install router 192.168.1.100
```

This will:
1. Connect to the target via SSH (must be booted into NixOS installer)
2. Partition and format disks using the host's disko configuration
3. Install NixOS with the specified host configuration
4. Automatically reboot into the new system

#### Regular Deployments

For updating existing systems using [deploy-rs](https://github.com/serokell/deploy-rs):

```bash
# Deploy configuration changes
just deploy <hostname>

# Deploy with boot activation (for kernel/bootloader changes)
just boot <hostname>

# Deploy multiple hosts
just deploy router storage cloud

# Build locally and push to binary cache
just build <hostname>
```

#### Helper Commands

```bash
# Generate hardware configuration from a running system
just hardware-config <hostname> <target-host>

# List network interfaces on a router (useful for initial setup)
just router-interfaces <target-host>
```

### Building SD Images

```bash
# For Raspberry Pi 3
nix build .#packages.aarch64-linux.raspi3

# For NanoPi R2S (includes U-Boot)
just r2s
```

## 📚 Structure

- `hosts/` - Machine-specific configurations
- `modules/` - Reusable NixOS modules
- `home/` - Home-manager configurations
- `packages/` - Custom packages
- `secrets/` - Encrypted secrets (via agenix)
- `overlays/` - Nixpkgs overlays

## 📦 Custom Packages

This repository includes several custom packages that are automatically loaded via Haumea and exposed in the flake outputs:

### Monitoring & Observability
- **signoz-query-service** - SigNoz backend query service for traces, logs, and metrics
- **signoz-frontend** - SigNoz web UI for observability platform
- **signoz-clickhouse-schema** - ClickHouse database schema initialization for SigNoz
- **signoz-otel-collector** - OpenTelemetry collector configuration for SigNoz
- **network-metrics-exporter** - Custom Prometheus exporter for network metrics

### Network Services
- **natpmp-server** - NAT-PMP server implementation in Go for port forwarding
- **supabase-manager** - Python tool for managing Supabase instances

### Utilities
- **check-stock** - Stock availability checker with email notifications
- **send-email-event** - Email notification service for system events

### Building Custom Packages

```bash
# Build a specific package
nix build .#signoz-frontend
nix build .#natpmp-server

# List all custom packages
nix flake show | grep packages
```

## 🔧 Tooling

This project uses:

- Nix Flakes
- Home Manager
- Agenix
- deploy-rs
- disko
- Attic (for binary cache)
- Colmena
- flake-parts

## 📝 Commit Style

Git commits follow the angular style with emojis:

- ✨ feat: new features
- 🐛 fix: bug fixes
- 📚 docs: documentation changes
- 💎 style: formatting changes
- 📦 refactor: code restructuring
- 🚀 perf: performance improvements
- 🧪 test: test updates
- 🛠️ build: build system changes
- 👷 ci: CI configuration
- 🧹 chore: maintenance tasks
- ⏪ revert: reverts previous commits

## 📄 License

This project is for personal use, but feel free to take inspiration from it for your own NixOS configurations! ❤️ 