# Media System Architecture

This document provides comprehensive documentation for the media system architecture in this NixOS configuration repository. The media system is designed as a modular, container-based infrastructure for managing media services with automated routing, authentication, and deployment.

## Overview

The media system consists of three main components:

1. **Core Media Modules** (`modules/media/`) - Low-level configuration and container management
2. **Constellation Media Module** (`modules/constellation/media.nix`) - High-level service definitions
3. **Gateway System** - Automated reverse proxy and authentication

## Architecture Components

### 1. Core Media Modules (`modules/media/`)

#### Configuration Module (`config.nix`)

Provides global configuration for the media system:

```nix
media.config = {
  enable = true;
  configDir = "/var/data";        # Container config storage
  dataDir = "/mnt/storage";       # Data directory
  storageDir = "/mnt/storage";    # Storage mount point
  puid = 5000;                    # Process user ID
  pgid = 5000;                    # Process group ID
  user = "media";                 # System user
  group = "media";                # System group
  tz = "America/Toronto";         # Timezone
  email = "arsfeld@gmail.com";    # Contact email
  domain = "arsfeld.one";         # Primary domain
  tsDomain = "bat-boa.ts.net";    # Tailscale domain
};
```

**Key Features:**
- Creates system user/group with specified UID/GID
- Configures ACME SSL certificates with Cloudflare DNS
- Sets up domain and timezone defaults

#### Container Management (`containers.nix`)

Defines the container abstraction layer with these options:

```nix
media.containers = {
  service-name = {
    enable = true;                    # Enable/disable service
    name = "service-name";            # Container name (auto-derived)
    listenPort = 8080;               # Port service listens on
    exposePort = null;               # External port (auto-generated if null)
    image = "ghcr.io/linuxserver/service-name";  # Docker image
    
    # Volume management
    volumes = [];                    # Additional volume mounts
    mediaVolumes = false;           # Mount media directories
    configDir = "/config";          # Container config path
    
    # Runtime options
    environment = {};               # Environment variables
    extraOptions = [];              # Additional docker options
    network = null;                 # Custom network
    privileged = false;             # Privileged mode
    devices = [];                   # Device mappings
    
    # Deployment
    host = "storage";               # Target host
    
    # Gateway settings
    settings = {
      cors = false;                 # Enable CORS
      insecureTls = false;         # Skip TLS verification
      bypassAuth = false;          # Skip authentication
      funnel = false;              # Enable Tailscale funnel
    };
  };
};
```

**Automatic Features:**
- Port assignment via hash-based algorithm (`nameToPort`)
- Volume directory creation via systemd-tmpfiles
- Media volume mounting (`/files`, `/media`)
- Standard environment variables (PUID, PGID, TZ)
- Service dependencies for media volumes

#### Gateway System (`gateway.nix`)

Manages reverse proxy and authentication:

```nix
media.gateway = {
  enable = true;
  domain = "arsfeld.one";
  authHost = "cloud.bat-boa.ts.net";
  authPort = 443;
  email = "arsfeld@gmail.com";
  
  services = {
    service-name = {
      enable = true;
      name = "service-name";
      host = "storage";
      port = 8080;
      settings = {
        cors = false;
        insecureTls = false;
        bypassAuth = false;
        funnel = false;
      };
    };
  };
};
```

**Generated Infrastructure:**
- Caddy reverse proxy configuration
- ACME SSL certificates with wildcard support
- Forward authentication via external auth service
- Tailscale service exposure (tsnsrv)
- CORS headers and error pages

#### Utility Functions (`__utils.nix`)

Core utility functions for configuration generation:

##### `generateHost`
Creates Caddy virtual host configurations:
```nix
generateHost {
  domain = "example.com";
  cfg = {
    name = "app";
    host = "server1";
    port = 8080;
    settings = {};
  };
}
# Returns: { "app.example.com" = { useACMEHost = "example.com"; extraConfig = "..."; }; }
```

##### `generateTsnsrvService`
Creates tsnsrv service configurations:
```nix
generateTsnsrvService {
  cfg = {
    name = "api";
    host = "localhost";
    port = 3000;
    settings.funnel = true;
  };
}
# Returns: { "api" = { toURL = "http://127.0.0.1:3000"; funnel = true; }; }
```

##### `generateCaddyExtraConfig`
Creates global Caddy configuration with CORS and error handling.

### 2. Constellation Media Module

The constellation layer provides high-level service definitions that utilize the core media system:

```nix
constellation.media.enable = true;
```

This enables predefined service configurations for two host categories:

#### Storage Services (host: "storage")
Media and content management services:

| Service | Port | Features | Description |
|---------|------|----------|-------------|
| nextcloud | 443 | insecureTls, custom volumes | File sync and sharing |
| overseerr | 5055 | - | Media request management |
| jackett | 9117 | - | Torrent indexer proxy |
| bazarr | 6767 | mediaVolumes | Subtitle management |
| radarr | 7878 | mediaVolumes | Movie automation |
| sonarr | 8989 | mediaVolumes | TV show automation |
| prowlarr | 9696 | - | Indexer management |
| autobrr | 7474 | - | Torrent automation |
| pinchflat | 8945 | custom volumes | YouTube downloading |
| plex | - | mediaVolumes, host network, GPU | Media server |
| stash | - | mediaVolumes, host network, GPU | Media organization |
| flaresolverr | 8191 | - | Cloudflare solver |
| kavita | 5000 | custom volumes | Digital library |

#### Cloud Services (host: "cloud")
Blog and content services:

| Service | Port | Features | Description |
|---------|------|----------|-------------|
| ghost | 2368 | custom config | Blog platform |

### 3. Port Management

The system uses a deterministic port assignment algorithm:

```nix
# nameToPort function in common/nameToPort.nix
nameToPort = name: let
  hash = builtins.substring 0 6 (builtins.hashString "sha256" name);
  decimal = (builtins.fromTOML "a = 0x${hash}").a;
  portRange = 65535 - 1024;
  remainder = decimal - (portRange * (decimal / portRange));
  port = 1024 + remainder;
in port;
```

**Benefits:**
- Deterministic port assignment
- Avoids port conflicts
- Consistent across deployments
- Range: 1024-65535

## Service Configuration Examples

### Basic Service
```nix
media.containers.jellyfin = {
  listenPort = 8096;
  mediaVolumes = true;
};
```

### Advanced Service with Custom Configuration
```nix
media.containers.plex = {
  environment = {
    VERSION = "latest";
  };
  mediaVolumes = true;
  network = "host";
  devices = ["/dev/dri:/dev/dri"];
  settings = {
    bypassAuth = true;
  };
};
```

### Service with Custom Volumes
```nix
media.containers.nextcloud = {
  listenPort = 443;
  volumes = [
    "${vars.storageDir}/files/Nextcloud:/data"
  ];
  settings = {
    insecureTls = true;
  };
};
```

## Deployment Patterns

### Host-Specific Deployment
Services automatically deploy to specified hosts:
```nix
# Service will only run on "storage" host
media.containers.plex = {
  host = "storage";
  # ... other config
};
```

### Multi-Host Configuration
Different services on different hosts:
```nix
# In constellation/media.nix
storageServices = { /* media services */ };
cloudServices = { /* blog services */ };

lib.mapAttrs (addHost "storage") storageServices // 
lib.mapAttrs (addHost "cloud") cloudServices;
```

## Authentication Integration

### Forward Authentication
All services integrate with forward authentication by default:
```nix
# In __utils.nix generateHost function
authConfig = optionalString (!cfg.settings.bypassAuth) ''
  forward_auth ${authHost}:${toString authPort} {
    uri /api/verify?rd=https://auth.${domain}/
    copy_headers Remote-User Remote-Groups Remote-Name Remote-Email
  }
'';
```

### Bypassing Authentication
For services that handle their own auth:
```nix
media.containers.service-name = {
  settings = {
    bypassAuth = true;
  };
};
```

## Volume Management

### Standard Volume Patterns
- **Config volumes**: `${configDir}/${name}:/config`
- **Media volumes**: `${dataDir}/files:/files`, `${storageDir}/media:/media`
- **Custom volumes**: User-defined mappings

### Directory Creation
Automatic directory creation via systemd-tmpfiles:
```nix
systemd.tmpfiles.rules = [
  "d ${configDir}/${name} 0775 ${user} ${group} -"
  # ... additional volume directories
];
```

## SSL and Domain Management

### Automatic SSL
- Wildcard certificates via ACME + Cloudflare DNS
- Domain: `service.${domain}` (e.g., `plex.arsfeld.one`)
- Automatic renewal and deployment

### Tailscale Integration
- Internal services: `service.${tsDomain}` (e.g., `plex.bat-boa.ts.net`)
- Funnel support for external exposure

## Advanced Features

### CORS Support
Enable cross-origin requests:
```nix
media.containers.api-service = {
  settings = {
    cors = true;
  };
};
```

### Insecure TLS
For services with self-signed certificates:
```nix
media.containers.internal-service = {
  settings = {
    insecureTls = true;
  };
};
```

### GPU Access
For hardware transcoding:
```nix
media.containers.media-server = {
  devices = ["/dev/dri:/dev/dri"];
  # or for full GPU access:
  # extraOptions = ["--gpus=all"];
};
```

### Host Networking
For services requiring host network access:
```nix
media.containers.network-service = {
  network = "host";
};
```

## Monitoring and Debugging

### Service Status
Check container status:
```bash
podman ps
systemctl status podman-<service-name>
```

### Service Information
Auto-generated service information:
```bash
cat /etc/services.json
```

### Port Mappings
Debug port assignments:
```bash
# Check generated port for service
nix eval --expr 'import ./common/nameToPort.nix "jellyfin"'
```

### Logs
View service logs:
```bash
podman logs <service-name>
journalctl -u podman-<service-name>
```

## Best Practices

### Service Definition
1. Use constellation layer for standard services
2. Override in host-specific config for customization
3. Use descriptive service names
4. Enable mediaVolumes for media-related services

### Security
1. Keep authentication enabled unless necessary
2. Use HTTPS with proper certificates
3. Limit exposed ports
4. Regular security updates

### Performance
1. Use host networking for high-throughput services
2. Enable GPU acceleration where supported
3. Monitor resource usage
4. Use appropriate storage backends

### Maintenance
1. Regular backup of config directories
2. Monitor certificate expiration
3. Update container images regularly
4. Test service functionality after changes

## Related Documentation

- [Constellation Modules](constellation.md) - High-level module system
- [Storage Host](../hosts/storage.md) - Primary media server configuration
- [Authentication](../architecture/authentication.md) - Authentication system
- [Network Architecture](../architecture/network.md) - Network design