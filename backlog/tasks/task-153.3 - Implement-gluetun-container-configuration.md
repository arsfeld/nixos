---
id: task-153.3
title: Implement gluetun container configuration
status: Done
assignee: []
created_date: '2025-11-30 19:31'
updated_date: '2025-11-30 19:56'
labels:
  - implementation
  - containers
dependencies:
  - task-153.1
  - task-153.2
parent_task_id: task-153
priority: medium
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Implement the gluetun container part of the module that connects to AirVPN.

## Gluetun Container Requirements

```nix
virtualisation.oci-containers.containers."gluetun-${name}" = {
  image = "qmcgaw/gluetun:latest";
  
  environment = {
    VPN_SERVICE_PROVIDER = "airvpn";
    VPN_TYPE = "wireguard";
    SERVER_COUNTRIES = cfg.country; # e.g., "Brazil"
    # Keys injected via environmentFiles or secrets
  };
  
  # Required capabilities
  extraOptions = [
    "--cap-add=NET_ADMIN"
    "--device=/dev/net/tun:/dev/net/tun"
  ];
  
  # Secret injection
  environmentFiles = [ cfg.secrets.envFile ];
  # Or individual secret mounts
};
```

## Key Considerations

1. **Secret injection** - Use environmentFiles for WireGuard credentials
2. **Health check** - Gluetun has built-in health endpoint at `:8000/v1/publicip/ip`
3. **DNS** - Gluetun handles DNS-over-TLS by default
4. **Firewall** - May need `--sysctl net.ipv4.conf.all.src_valid_mark=1`
5. **Logging** - Consider log level configuration

## Health Check Integration

Gluetun exposes health status:
- `http://localhost:8000/v1/publicip/ip` - Returns current public IP
- Can be used to verify VPN is connected before Tailscale advertises
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Gluetun container starts and connects to AirVPN
- [x] #2 Container uses correct country/region server
- [x] #3 WireGuard credentials loaded from sops secrets
- [x] #4 Health endpoint accessible for monitoring
- [x] #5 Container restarts on failure
<!-- AC:END -->
