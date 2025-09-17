+++
title = "Simplifying NixOS Configurations with Reusable Modules"
date = 2025-06-11
aliases = ["/posts/constellation-pattern/"]
description = "A modular system for managing multiple NixOS machines that eliminates configuration duplication while maintaining flexibility"
tags = ["nixos", "infrastructure", "self-hosting", "constellation-pattern"]
+++

![NixOS Constellation Pattern - A network of connected nodes representing modular infrastructure](/images/constellation-pattern-hero.png)

Managing multiple NixOS machines quickly becomes unwieldy when you copy-paste configurations between hosts. You end up with duplicated code, inconsistent settings, and the nightmare of keeping everything in sync. After running a fleet of 10+ NixOS machines ranging from ARM routers to x86 servers, I developed what I call the "Constellation Pattern" - a modular system that eliminates configuration duplication while maintaining the flexibility to customize each host.

> **Note**: All code examples in this post are from my real production NixOS configuration, available at [github.com/arsfeld/nixos](https://github.com/arsfeld/nixos).

## The Problem with Traditional NixOS Multi-Host Management

![Configuration drift and copy-paste problems in traditional NixOS setups](/images/configuration-drift-problems.png)

Most NixOS configurations start simple. You have one machine, one `configuration.nix`, and life is good. But as you add more hosts, you face several challenges:

**Configuration Drift**: Each host accumulates unique tweaks, making it impossible to apply consistent updates across your fleet.

**Copy-Paste Hell**: You copy working configurations between machines, creating maintenance nightmares when you need to update common settings.

**All-or-Nothing Modules**: Standard NixOS modules are often too rigid - you can't easily enable just the parts you need on different hosts.

**Dependency Management**: Services on one host might depend on services running on another host, but there's no clean way to express these relationships.

Here's what a typical problematic setup looks like:

```nix
# hosts/server1/configuration.nix
{ pkgs, ... }: {
  # 200 lines of common configuration
  services.tailscale.enable = true;
  services.openssh.enable = true;
  # ... lots of repeated configuration
  
  # Server-specific stuff mixed in
  services.postgresql.enable = true;
}

# hosts/server2/configuration.nix  
{ pkgs, ... }: {
  # Same 200 lines copied and pasted
  services.tailscale.enable = true;
  services.openssh.enable = true;
  # ... same repeated configuration
  
  # Different server-specific stuff
  services.nginx.enable = true;
}
```

## Enter the Constellation Pattern

![Constellation pattern architecture showing modular, composable infrastructure](/images/constellation-architecture.png)

The Constellation Pattern solves this by creating **opt-in feature modules** that can be selectively enabled on any host. Instead of copying configuration, you compose your hosts from a set of reusable, well-tested modules.

The pattern consists of:

1. **Base Module (`constellation.common`)**: Common configuration that nearly every host needs
2. **Feature Modules**: Specialized modules for specific capabilities (media, backup, services, etc.)
3. **Host Configurations**: Minimal files that just enable the modules they need

Here's how my hosts are now configured:

```nix
# hosts/storage/configuration.nix
{
  constellation.backup.enable = true;
  constellation.services.enable = true;
  constellation.media.enable = true;
  constellation.podman.enable = true;
  
  # Host-specific configuration
  networking.hostName = "storage";
  # ... minimal host-specific settings
}

# hosts/cloud/configuration.nix  
{
  constellation.podman.enable = true;
  constellation.backup.enable = true;
  constellation.services.enable = true;
  constellation.media.enable = true;
  constellation.supabase.enable = true;
  
  # Host-specific configuration
  networking.hostName = "cloud";
  nixpkgs.hostPlatform = "aarch64-linux";
}
```

Clean, declarative, and immediately obvious what each host provides.

## Anatomy of a Constellation Module

Let's examine the `constellation.common` module to understand the pattern:

```nix
# modules/constellation/common.nix
# Source: https://github.com/arsfeld/nixos/blob/master/modules/constellation/common.nix
{
  inputs,
  config,
  pkgs,
  lib,
  ...
}:
with lib; {
  options.constellation.common = {
    enable = mkOption {
      type = types.bool;
      description = "Enable common configuration";
      default = true;  # This is key - enabled by default
    };
  };

  config = lib.mkIf config.constellation.common.enable {
    # Nix configuration that every host needs
    nix = {
      settings = {
        experimental-features = "nix-command flakes";
        auto-optimise-store = true;
        substituters = [
          "https://nix-community.cachix.org?priority=41"
          "https://fly-attic.fly.dev/system"
          # ... more caches
        ];
        trusted-public-keys = [
          "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
          # ... corresponding keys
        ];
      };
    };

    # Essential services every host needs
    services.tailscale.enable = true;
    services.openssh.enable = true;
    services.avahi.enable = true;
    
    # Common packages
    environment.systemPackages = with pkgs; [
      git htop tmux wget
      # ... essential tools
    ];
    
    # Security and performance defaults
    networking.firewall.trustedInterfaces = ["tailscale0"];
    zramSwap.enable = true;
    nix.gc = {
      automatic = true;
      dates = "Sat *-*-* 03:15:00";
      options = "--delete-older-than 30d";
    };
  };
}
```

Key principles:

- **Single Responsibility**: Each module has a clear, focused purpose
- **Sensible Defaults**: The module works out of the box with minimal configuration
- **Override Capability**: Hosts can still override specific settings when needed
- **Dependency Declaration**: Modules can reference other constellation modules

## Real-World Example: Mixing Containers and Native Services

The true power of the Constellation Pattern emerges when modules orchestrate both container-based and native NixOS services seamlessly. This hybrid approach lets you choose the best deployment method for each service while maintaining a unified gateway and service discovery system.

### Why the Hybrid Approach?

My `constellation.media` module runs the *arr stack (Sonarr, Radarr, Prowlarr) as containers because:
- NixOS modules for these services weren't updated frequently enough
- Container images provide consistent configuration across updates
- The *arr ecosystem expects certain behaviors that containers handle better

Meanwhile, services deeply integrated with NixOS (like PostgreSQL databases, Grafana, or Gitea) run as native services for better system integration.

### The Media Constellation in Action

```nix
# modules/constellation/media.nix
# Container-based services with automatic deployment
{
  config = lib.mkIf cfg.enable {
    media.containers = let
      storageServices = {
        # The full *arr stack as containers
        prowlarr = { listenPort = 9696; };
        sonarr = { 
          listenPort = 8989;
          mediaVolumes = true;  # Automatically mounts media directories
        };
        radarr = { 
          listenPort = 7878;
          mediaVolumes = true;
        };
        
        # Media servers with hardware acceleration
        plex = {
          mediaVolumes = true;
          network = "host";
          devices = ["/dev/dri:/dev/dri"];  # Intel GPU passthrough
        };
      };
    in
      lib.mapAttrs (addHost "storage") storageServices;
  };
}

# modules/constellation/services.nix
# Native NixOS services registered for gateway routing
let
  services = {
    storage = {
      # Native services get simple port registration
      grafana = 3010;
      gitea = 3001;
      postgresql = 5432;
      # Container services just need their exposed port
      jellyfin = 8096;
      immich = 15777;
      sonarr = 8989;
      radarr = 7878;
    };
  };
```

### Unified Gateway System

Both container and native services register with the same gateway system:

```nix
# All services - container or native - get automatic:
# - Reverse proxy configuration (https://service.domain.com)
# - Service discovery across hosts
# - Authentication rules
# - Health monitoring

media.gateway = {
  enable = true;
  services = generateServices services;  # Works for both types!
};
```

The beauty of this approach:
- **Use containers when they make sense**: For services with complex dependencies or frequent updates
- **Use native when better**: For NixOS-integrated services or those needing deep system access
- **Same gateway for everything**: Users don't know or care how services are deployed
- **Flexible migration**: Start with native, move to containers (or vice versa) without changing the gateway configuration

This flexibility is where the constellation system truly shines - it doesn't force you into one deployment model but lets you choose the best tool for each job while maintaining a cohesive system.

## Benefits of the Constellation Pattern

After running this pattern for over a year across 10+ hosts, the benefits are substantial:

**Consistency**: Every host gets the same base configuration, eliminating configuration drift.

**Maintainability**: Updating all hosts is as simple as updating a single module and redeploying.

**Composability**: New hosts are trivial to create - just enable the modules you need.

**Testing**: You can test new configurations on a single host before rolling out to the fleet.

**Documentation**: The module structure serves as living documentation of your infrastructure capabilities.

**Flexibility**: Hosts can still override specific settings when needed, maintaining NixOS's flexibility.

## Comparison with Alternatives

**vs. NixOps**: More lightweight and doesn't require a separate deployment tool. Works with any deployment method (deploy-rs, nixos-rebuild, etc.).

**vs. Terraform/Ansible**: Purely declarative with NixOS's atomic rollback capabilities. No imperative state management.

**vs. Kubernetes**: Simpler for homelab scale. No YAML hell, built-in secret management, and works on bare metal.

**vs. Docker Compose**: Better hardware integration, atomic updates, and cross-host service discovery built-in.

## How It All Ties Together: Automatic Module Loading with Haumea

The magic that makes the Constellation Pattern truly effortless is [haumea](https://github.com/nix-community/haumea), a library that automatically loads all files as NixOS modules. Instead of manually importing each module file, haumea discovers and loads them for you:

```nix
# flake.nix
# Source: https://github.com/arsfeld/nixos/blob/master/flake.nix
let
  modules = inputs.haumea.lib.load {
    src = ./modules;
    loader = inputs.haumea.lib.loaders.path;
  };
in
  getAllValues modules  # Flattens nested module structure
```

This means:
- **Zero Import Boilerplate**: Drop a new `.nix` file in `modules/` and it's automatically available
- **Nested Organization**: Create subdirectories like `constellation/` for logical grouping
- **Instant Recognition**: New constellation modules are immediately available to all hosts
- **Clean Flake**: Your `flake.nix` stays minimal and focused

Combined with the constellation pattern, this creates a self-organizing module system where adding new capabilities is as simple as creating a file in the right directory.

## Advanced Patterns: A Glimpse into the Future

The Constellation Pattern enables sophisticated infrastructure patterns that would be complex to implement otherwise. Multi-host service meshes, automatic service discovery, hardware-aware deployments, and declarative secret distribution all become straightforward.

In a future post, we'll explore these advanced patterns in detail, showing how constellation modules can orchestrate complex multi-host deployments, handle cross-host dependencies, and create self-healing infrastructure - all while maintaining the simplicity of enabling a single option.

## Conclusion

The Constellation Pattern has transformed how I manage my self-hosted infrastructure. What started as a mess of copy-pasted configurations is now a clean, maintainable system that scales from a single Raspberry Pi to a full server fleet. By combining opt-in modules with automatic loading via haumea, the pattern achieves both flexibility and simplicity - the holy grail of infrastructure management.