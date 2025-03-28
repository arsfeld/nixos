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

### Deploying

```bash
# Deploy a specific system
deploy --remote-build=false --skip-checks --targets ".#hostname" --boot

# Or use the CI pipeline for building
```

### Building SD Images

```bash
# For Raspberry Pi
nix build .#packages.aarch64-linux.raspi3
```

## 📚 Structure

- `hosts/` - Machine-specific configurations
- `modules/` - Reusable NixOS modules
- `home/` - Home-manager configurations
- `packages/` - Custom packages
- `secrets/` - Encrypted secrets (via agenix)
- `overlays/` - Nixpkgs overlays

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