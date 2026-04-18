# NixOS Infrastructure Documentation

Welcome to the comprehensive documentation for a personal NixOS infrastructure setup. This repository manages multiple machines using Nix Flakes, providing a declarative and reproducible system configuration.

## Overview

This infrastructure consists of:

- **9+ Systems**: Including servers, desktops, and embedded devices
- **50+ Services**: Self-hosted applications for media, development, and productivity
- **Unified Authentication**: Single sign-on across all services
- **Automated Deployment**: Using deploy-rs and GitHub Actions
- **Comprehensive Backup**: Multiple backup strategies and destinations

## Quick Links

<div class="grid cards" markdown>

- :material-server: **[Hosts](hosts/overview.md)**  
  Documentation for each system in the infrastructure

- :material-puzzle: **[Media Stack](modules/media.md)**  
  Reusable NixOS modules and configurations

- :material-cloud: **[Services](services/catalog.md)**  
  Catalog of all self-hosted services

- :material-security: **[Authentication](architecture/authentication.md)**  
  How the SSO system works

- :material-book-open: **[Guides](guides/getting-started.md)**  
  How-to guides and tutorials

</div>

## Key Features

### 🏗️ Infrastructure as Code
Everything is declaratively configured using Nix, from disk partitioning to service deployment.

### 🔐 Unified Authentication
Single sign-on using LLDAP + Dex + Authelia provides secure access to all services.

### 🌐 Secure Networking
Tailscale VPN connects all hosts securely, with Caddy providing HTTPS reverse proxy.

### 📦 Container-First
Most services run in Podman containers for isolation and easy updates.

### 💾 Automated Backups
Weekly backups to multiple destinations using Rustic (Restic-compatible).

### 📊 Comprehensive Monitoring
Netdata, Grafana, and custom alerts keep track of system health.

## Getting Started

1. **[Architecture Overview](architecture/overview.md)** - Understand the system design
2. **[Service Catalog](services/catalog.md)** - Explore available services
3. **[Getting Started](guides/getting-started.md)** - Set up your environment

## Repository Structure

```
nixos/
├── hosts/          # Machine-specific configurations
├── modules/        # Reusable NixOS modules
├── home/           # Home Manager configurations
├── secrets/        # Encrypted secrets (sops-nix)
├── overlays/       # Nixpkgs overlays
├── flake.nix       # Flake definition
└── flake-modules/  # Flake-parts modules (deployment, dev, etc.)
```