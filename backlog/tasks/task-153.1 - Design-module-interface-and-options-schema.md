---
id: task-153.1
title: Design module interface and options schema
status: Done
assignee: []
created_date: '2025-11-30 19:31'
updated_date: '2025-11-30 19:55'
labels:
  - design
dependencies: []
parent_task_id: task-153
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Design the NixOS module interface for defining VPN exit nodes.

## Proposed Interface

```nix
constellation.vpnExitNodes = {
  enable = true;
  
  nodes = {
    brazil = {
      country = "Brazil";
      # Or more specific:
      # city = "Sao Paulo";
      # region = "South America";
      
      tailscaleHostname = "brazil-exit";
      
      # Secrets reference (sops-nix paths)
      secrets = {
        wireguardPrivateKey = "airvpn/brazil/private-key";
        wireguardPresharedKey = "airvpn/brazil/preshared-key";
        wireguardAddress = "airvpn/brazil/address";
        # Or single secret file with all values
        # configFile = config.sops.secrets.airvpn-brazil.path;
      };
    };
    
    us = {
      country = "United States";
      tailscaleHostname = "us-exit";
      # ...
    };
  };
  
  # Shared settings
  tailscaleAuthKeyFile = config.sops.secrets.tailscale-exit-key.path;
};
```

## Design Decisions Needed

1. **Secret structure** - Individual keys vs single config file?
2. **Server selection** - Country only, or support city/region/hostname?
3. **Container runtime** - Podman (existing) or Docker?
4. **Health checks** - How to verify VPN is working before advertising exit node?
5. **Naming convention** - Container names, Tailscale hostnames
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Module options schema defined with types
- [x] #2 Interface supports multiple exit nodes
- [x] #3 Secret paths configurable
- [x] #4 Server filtering options (country/city/region) supported
<!-- AC:END -->
