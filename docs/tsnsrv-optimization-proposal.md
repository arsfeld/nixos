# Caddy with Tailscale Plugin - Implementation Guide

## Current State Analysis

### Problem Statement
- **57 tsnsrv processes** running on storage host, each consuming ~0.7% CPU and ~42MB RAM
- Total resource usage: ~40% CPU and ~2.4GB RAM just for proxying
- Each service requires its own Tailscale node with separate state directory
- Authentication is configured but applies uniformly (no distinction between internal/external traffic)

### Current Architecture
```
Internet → Tailscale Funnel → tsnsrv (per service) → Local Service
Tailnet  → tsnsrv (per service) → Local Service
```

Each tsnsrv instance:
- Maintains its own Tailscale connection
- Has authentication configured (Authelia at cloud.bat-boa.ts.net:63836)
- Bypasses auth for Tailnet users (`authBypassForTailnet=true`)
- Forwards user headers (Remote-User, Remote-Groups, etc.)

### Services with Funnel (Public Access)
- code, filebrowser, filerun, filestash, gitea, grafana
- grocy, hass, home, immich, jellyfin, jf, komga
- netdata, photos, plex, qbittorrent, romm, sabnzbd
- seafile, speedtest, syncthing, www

## Solution: Caddy with Tailscale Plugin

**Architecture:**
```
Internet → Tailscale Funnel → Caddy (single instance) → Local Services
Tailnet  → Caddy → Local Services
```

**Advantages:**
- Single process handling all routing
- Native Tailscale integration via tsnet library
- Automatic certificate management for *.ts.net domains
- Sophisticated routing and middleware capabilities
- Already running on the system

### OAuth Client Authentication Solution

**✅ Solved: Using chrishoage's fork of caddy-tailscale with OAuth support**

The original Caddy Tailscale plugin has a critical limitation with OAuth keys ([issue #48](https://github.com/tailscale/caddy-tailscale/issues/48)). However, [chrishoage's fork](https://github.com/chrishoage/caddy-tailscale) adds OAuth client support!

**Fork Features:**
- Full OAuth client authentication support
- Pinned to commit `559d3be3265d151136178bc04e4bf69a01c57889` for stability
- Allows using the same OAuth client secret across all services
- No need for per-service key generation

**Current tsnsrv Setup (can be reused):**
- Uses Tailscale OAuth client with `auth_key` permissions and `tag:service` tag
- OAuth client secret works as auth key (stored in `/run/agenix/tailscale-key`)
- All services automatically inherit tags from the OAuth client

### Solution: Single Caddy Instance with OAuth Authentication

**The optimal approach using the forked plugin:**
- Single Caddy process replacing 57 tsnsrv instances
- Direct OAuth client authentication
- No API key generation needed
- Simplified architecture

#### Implementation Details

```nix
# Build Caddy with the OAuth-supporting fork
{ pkgs, ... }:
let
  caddy-tailscale-oauth = pkgs.buildGoModule rec {
    pname = "caddy-tailscale-oauth";
    version = "unstable-2024-01-15";
    
    src = pkgs.fetchFromGitHub {
      owner = "chrishoage";
      repo = "caddy-tailscale";
      rev = "559d3be3265d151136178bc04e4bf69a01c57889";
      sha256 = "sha256-PLACEHOLDER"; # Replace with actual hash
    };
    
    vendorSha256 = "sha256-PLACEHOLDER"; # Replace with actual hash
  };
  
  caddyWithTailscale = pkgs.caddy.override {
    buildGoModule = args: pkgs.buildGoModule (args // {
      src = pkgs.stdenv.mkDerivation {
        pname = "caddy-with-plugins-src";
        version = pkgs.caddy.version;
        phases = [ "unpackPhase" "buildPhase" "installPhase" ];
        
        srcs = [ pkgs.caddy.src ];
        
        buildPhase = ''
          cp -r ${pkgs.caddy.src}/* .
          chmod -R +w .
          
          # Add the OAuth-supporting Tailscale plugin
          cat >> main.go <<EOF
          import _ "github.com/chrishoage/caddy-tailscale"
          EOF
          
          go mod edit -replace github.com/tailscale/caddy-tailscale=github.com/chrishoage/caddy-tailscale@${caddy-tailscale-oauth.src.rev}
          go mod tidy
        '';
        
        installPhase = ''
          cp -r . $out
        '';
      };
    });
  };
in {
  # Single Caddy instance with OAuth authentication
  services.caddy = {
    enable = true;
    package = caddyWithTailscale;
    
    # Global OAuth configuration
    globalConfig = ''
      {
        tailscale {
          auth_key {env.TS_AUTHKEY}
        }
      }
    '';
    
    # Service configurations
    virtualHosts = let
      mkService = name: service: {
        "${name}.bat-boa.ts.net" = {
          extraConfig = ''
            # Bind to Tailscale network with OAuth auth
            bind tailscale/${name}
            
            # Authentication based on service type
            ${if service.authType == "external" then ''
              # Auth only for external (non-Tailnet) traffic
              @external not remote_ip 100.64.0.0/10
              forward_auth @external cloud.bat-boa.ts.net:63836 {
                uri /api/verify?rd=https://auth.arsfeld.one/
                copy_headers Remote-User Remote-Groups Remote-Name Remote-Email
              }
            '' else if service.authType == "always" then ''
              # Always require auth
              forward_auth cloud.bat-boa.ts.net:63836 {
                uri /api/verify?rd=https://auth.arsfeld.one/
                copy_headers Remote-User Remote-Groups Remote-Name Remote-Email
              }
            '' else ""}
            
            # Proxy to local service
            reverse_proxy localhost:${toString service.port}
            
            # Enable funnel if needed
            ${if service.funnel then ''
              # Exposed via Tailscale Funnel
              tls {
                on_demand
              }
            '' else ""}
          '';
        };
      };
    in
      lib.mkMerge (lib.mapAttrsToList mkService cfg.services);
  };
  
  # Pass OAuth key to Caddy
  systemd.services.caddy = {
    serviceConfig.EnvironmentFile = config.age.secrets.tailscale-env.path;
  };
  
  # Create environment file with OAuth key
  age.secrets.tailscale-env = {
    file = ./secrets/tailscale-env.age;
    mode = "0400";
    owner = "caddy";
    # Content: TS_AUTHKEY=tskey-client-xxxxx
  };
}
```

#### Key Benefits with OAuth Fork

**Simplified Architecture:**
- Single Caddy process instead of 57 tsnsrv or multiple Caddy instances
- Direct OAuth authentication without API calls
- No key generation or lifecycle management needed

**Reuses Existing Infrastructure:**
- Same OAuth client secret already in use
- Same `tag:service` tagging
- Same authentication patterns

**Performance Improvements:**
- ~95% reduction in processes (57 → 1)
- ~90% reduction in memory usage
- ~85% reduction in CPU usage
- Single Tailscale connection instead of 57

#### Migration Strategy

1. **Phase 1: Build and Test**
   - Build Caddy with the OAuth fork
   - Test with 2-3 non-critical services
   - Verify OAuth authentication works
   - Confirm auth bypass for Tailnet users

2. **Phase 2: Gradual Migration**
   - Group services by authentication requirements
   - Migrate internal-only services first
   - Migrate mixed services with auth rules
   - Migrate public services last

3. **Phase 3: Cleanup**
   - Disable all tsnsrv services
   - Remove tsnsrv module configuration
   - Consolidate all routing in single Caddy instance

## Rejected Solutions

### ❌ API-Based Key Generation
**Why Rejected:** Unnecessary complexity when OAuth fork solves the problem directly

### ❌ Multiple Caddy Instances
**Why Rejected:** Defeats purpose of consolidation, still maintains multiple processes

### ❌ Long-Lived Auth Keys (90-day)
**Why Rejected:** Requires manual renewal, operational burden

## Recommended Solution: Single Caddy with OAuth Fork

Using the chrishoage fork of caddy-tailscale enables the optimal architecture:

```
Internet → Tailscale Funnel → Caddy (single instance) → Local Services
Tailnet  → Caddy → Local Services
```

### Benefits
- **Maintains OAuth authentication** - Direct OAuth support, no workarounds
- **Reduces processes** - From 57 tsnsrv to 1 Caddy instance
- **Flexible routing** - Full Caddy capabilities for routing and middleware
- **Simplified management** - Single configuration point for all services
- **No key lifecycle management** - OAuth client handles authentication


## Authentication Strategy

### Current Issue
- All funnel services expose to internet with same auth rules
- No way to differentiate between internal (Tailnet) and external (Funnel) traffic in auth decisions

### Proposed Solution

**Three-Tier Authentication:**

1. **Internal Services (Tailnet Only)**
   - No authentication required
   - Only accessible from Tailnet
   - Example: autobrr, bazarr, sonarr, radarr

2. **Mixed Services (Tailnet + Funnel)**
   - No auth for Tailnet users
   - Authelia auth for external users
   - Example: jellyfin, immich, nextcloud

3. **Public Services**
   - Own authentication (bypass Authelia)
   - Example: gitea, grafana, hass

**Implementation with Caddy:**

```nix
# Service configuration with proper virtual hosts
services.caddy.virtualHosts = let
  # Helper to generate service configuration
  mkService = name: port: funnel: authType: {
    # Use the Tailscale domain
    "https://${name}.bat-boa.ts.net" = {
      extraConfig = ''
        # Bind to Tailscale interface
        bind tailscale/${name}
        
        ${if authType == "external" then ''
          # Auth only for external (non-Tailnet) traffic
          @external not remote_ip 100.64.0.0/10
          forward_auth @external cloud.bat-boa.ts.net:63836 {
            uri /api/verify?rd=https://auth.arsfeld.one/
            copy_headers Remote-User Remote-Groups Remote-Name Remote-Email
          }
        '' else if authType == "always" then ''
          # Always require auth
          forward_auth cloud.bat-boa.ts.net:63836 {
            uri /api/verify?rd=https://auth.arsfeld.one/
            copy_headers Remote-User Remote-Groups Remote-Name Remote-Email
          }
        '' else ""}
        
        # Proxy to local service
        reverse_proxy localhost:${toString port}
        
        # Enable funnel if needed
        ${if funnel then ''
          # This service is exposed via Tailscale Funnel
          # Configuration handled by tailscale serve commands
        '' else ""}
      '';
    };
  };
in {
  # Internal services (no funnel, no auth for Tailnet)
  } // mkService "autobrr" 11619 false "none"
  // mkService "bazarr" 44129 false "none"
  // mkService "sonarr" 8989 false "none"
  // mkService "radarr" 7878 false "none"
  
  # Mixed services (funnel enabled, auth for external only)
  // mkService "jellyfin" 8096 true "external"
  // mkService "immich" 2283 true "external"
  // mkService "filebrowser" 38080 true "external"
  // mkService "nextcloud" 8099 true "external"
  
  # Public services (funnel enabled, own auth)
  // mkService "gitea" 3001 true "none"
  // mkService "grafana" 3010 true "none"
  // mkService "hass" 8123 true "none";
```

**Tailscale Funnel Configuration:**
```nix
# Automatically configure Tailscale Funnel for services
systemd.services.tailscale-caddy-funnel = {
  after = [ "tailscaled.service" "caddy.service" ];
  wantedBy = [ "multi-user.target" ];
  serviceConfig = {
    Type = "oneshot";
    RemainAfterExit = true;
  };
  script = ''
    # Wait for Tailscale to be ready
    sleep 10
    
    # Configure funnel for each public service
    ${pkgs.tailscale}/bin/tailscale serve https:443 /jellyfin proxy https://localhost:443
    ${pkgs.tailscale}/bin/tailscale serve https:443 /immich proxy https://localhost:443
    ${pkgs.tailscale}/bin/tailscale serve https:443 /filebrowser proxy https://localhost:443
    
    # Enable funnel
    ${pkgs.tailscale}/bin/tailscale funnel 443 on
  '';
};
```

## Resource Savings Estimate

### Current Usage (57 tsnsrv processes)
- CPU: ~40% baseline
- RAM: ~2.4GB
- Process overhead: 57 separate Tailscale connections

### Projected Usage (Single Caddy)
- CPU: ~5-10% (including routing for all services)
- RAM: ~200-300MB
- Process overhead: 1 Tailscale connection

### Savings
- **CPU: 30-35% reduction**
- **RAM: 2.1GB reduction**
- **Process count: 56 fewer processes**

## Migration Plan

### Phase 1: Proof of Concept
1. Build Caddy with Tailscale plugin
2. Configure 2-3 services as test
3. Verify authentication works correctly
4. Test funnel functionality

### Phase 2: Gradual Migration
1. Group services by authentication requirements
2. Migrate internal-only services first
3. Migrate mixed services with auth rules
4. Migrate public services last

### Phase 3: Cleanup
1. Disable tsnsrv services
2. Remove tsnsrv module usage
3. Consolidate configuration in Caddy

## Complete NixOS Module for Hybrid Solution

```nix
# modules/constellation/tsnsrv-gateway.nix
{ config, lib, pkgs, ... }:
let
  cfg = config.constellation.tsnsrvGateway;
  
  # Generate Caddy routing rules
  mkRoute = name: service: ''
    handle /${name}* {
      uri strip_prefix /${name}
      
      ${if service.additionalAuth then ''
        # Add extra authentication layer in Caddy
        forward_auth cloud.bat-boa.ts.net:63836 {
          uri /api/verify?rd=https://auth.arsfeld.one/
          copy_headers Remote-User Remote-Groups Remote-Name Remote-Email
        }
      '' else ""}
      
      reverse_proxy localhost:${toString service.port} {
        header_up X-Forwarded-Prefix /${name}
      }
    }
  '';
in {
  options.constellation.tsnsrvGateway = {
    enable = lib.mkEnableOption "Single tsnsrv gateway with Caddy routing";
    
    domain = lib.mkOption {
      type = lib.types.str;
      default = "gateway.bat-boa.ts.net";
      description = "Domain for the gateway";
    };
    
    services = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule {
        options = {
          port = lib.mkOption {
            type = lib.types.port;
            description = "Local port of the service";
          };
          
          public = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = "Expose via Tailscale Funnel";
          };
          
          additionalAuth = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = "Add Caddy-level authentication";
          };
        };
      });
      default = {};
    };
  };
  
  config = lib.mkIf cfg.enable {
    # Single tsnsrv gateway instance
    services.tsnsrv.services.gateway = {
      toURL = "http://127.0.0.1:80";
      funnel = true;  # Enable if any service needs public access
      
      # Authentication via Authelia for external traffic
      authURL = "http://cloud.bat-boa.ts.net:63836";
      authPath = "/api/verify?rd=https://auth.arsfeld.one/";
      authBypassForTailnet = true;
      
      # OAuth client authentication
      authKeyPath = config.age.secrets.tailscale-key.path;
      ephemeral = true;
      tags = ["tag:service"];
    };
    
    # Caddy for intelligent routing
    services.caddy = {
      enable = true;
      virtualHosts."localhost:80" = {
        extraConfig = ''
          # Health check endpoint
          handle /health {
            respond "OK" 200
          }
          
          # Service routing
          ${lib.concatStringsSep "\n" 
            (lib.mapAttrsToList mkRoute cfg.services)}
          
          # Default handler
          handle {
            respond "Service not found" 404
          }
        '';
      };
    };
    
    # Configure which paths are publicly accessible
    systemd.services.tsnsrv-funnel-config = {
      after = [ "tsnsrv-gateway.service" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = let
        publicServices = lib.filterAttrs (_: s: s.public) cfg.services;
      in ''
        sleep 10
        
        # Configure public paths
        ${lib.concatStringsSep "\n" (lib.mapAttrsToList (name: _: ''
          ${pkgs.tailscale}/bin/tailscale serve --bg /${name} proxy http://localhost:80/${name}
        '') publicServices)}
      '';
    };
  };
}
```

## Usage Example

```nix
# In your host configuration
constellation.caddyTailscale = {
  enable = true;
  
  services = {
    # Internal services - no authentication needed for Tailnet users
    autobrr = { port = 11619; };
    bazarr = { port = 44129; };
    sonarr = { port = 8989; };
    radarr = { port = 7878; };
    
    # Public services with conditional auth
    jellyfin = { 
      port = 8096; 
      funnel = true;
      auth = "external";  # Only auth external traffic
    };
    immich = { 
      port = 2283; 
      funnel = true;
      auth = "external";
    };
    
    # Services with their own authentication
    gitea = { 
      port = 3001; 
      funnel = true;
      auth = "none";  # Gitea handles its own auth
    };
    grafana = { 
      port = 3010; 
      funnel = true;
      auth = "none";  # Grafana has built-in auth
    };
  };
};
```

## OAuth Client Setup

1. **Create OAuth Client in Tailscale Admin:**
   - Go to Settings → OAuth clients
   - Click "Create OAuth client"
   - Select scopes: `auth_keys`
   - Add tags: `tag:service`
   - Save and copy the client secret

2. **Store the Client Secret:**
   ```bash
   # Encrypt the OAuth client secret
   echo "tskey-client-xxxxx" | ragenix -e secrets/tailscale-key.age
   ```

3. **Update secrets.nix:**
   ```nix
   "tailscale-key.age" = {
     publicKeys = [ storage ];
     owner = "caddy";
   };
   ```

## Benefits Summary

- **Resource Efficiency**: 85% reduction in proxy resource usage (from 57 processes to 1)
- **Simplified Architecture**: Single Caddy instance handles all routing
- **OAuth Reuse**: Same OAuth client secret authenticates all services
- **Granular Auth**: Different authentication strategies per service
- **Native Integration**: Uses Tailscale's tsnet library directly
- **Future-Proof**: Caddy's plugin ecosystem for additional features