---
id: task-153.5
title: Create the NixOS module file and integrate with constellation
status: Done
assignee: []
created_date: '2025-11-30 19:31'
updated_date: '2025-11-30 19:56'
labels:
  - implementation
  - nixos-module
dependencies:
  - task-153.1
  - task-153.3
  - task-153.4
parent_task_id: task-153
priority: medium
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Create the actual NixOS module file that ties everything together.

## File Location

`modules/constellation/vpn-exit-nodes.nix`

## Module Structure

```nix
{ config, lib, pkgs, ... }:

let
  cfg = config.constellation.vpnExitNodes;
  
  # Helper to create container pair for each exit node
  mkExitNode = name: nodeCfg: {
    # Gluetun container
    "gluetun-${name}" = { ... };
    # Tailscale container  
    "tailscale-${name}" = { ... };
  };
  
  # Merge all exit node containers
  allContainers = lib.mapAttrsToList mkExitNode cfg.nodes;
in {
  options.constellation.vpnExitNodes = {
    enable = lib.mkEnableOption "VPN exit nodes for Tailscale";
    
    nodes = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule { ... });
      default = {};
      description = "VPN exit node definitions";
    };
    
    tailscaleAuthKeyFile = lib.mkOption {
      type = lib.types.path;
      description = "Path to Tailscale auth key file";
    };
  };
  
  config = lib.mkIf cfg.enable {
    # Ensure podman is enabled
    constellation.podman.enable = true;
    
    # Create all containers
    virtualisation.oci-containers.containers = 
      lib.foldl' lib.recursiveUpdate {} allContainers;
  };
}
```

## Integration Points

1. Add to `modules/constellation/default.nix` imports
2. Ensure compatible with existing podman setup
3. Add systemd dependencies for secrets
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Module file created at modules/constellation/vpn-exit-nodes.nix
- [x] #2 Module imported in constellation default.nix
- [x] #3 Options properly typed with lib.types
- [x] #4 Helper function generates correct container configs
- [x] #5 Module integrates with existing podman setup
<!-- AC:END -->
