# Kubernetes Migration Guide

## Overview

This guide explores migrating the current NixOS infrastructure to Kubernetes (K3s) while maintaining the declarative configuration approach and keeping complexity minimal. The focus is on migrating the `storage` and `cloud` hosts, which run the majority of services.

## Current State Analysis

### What We Have
- **2 Active Hosts**: Storage (media/files) and Cloud (auth/public services)
- **50+ Services**: Running in Podman containers
- **Declarative Config**: Everything defined in Nix
- **Simple Deployment**: `just deploy hostname`
- **Integrated Secrets**: Age-encrypted secrets
- **Service Discovery**: Constellation modules

### What Works Well
- Single repository for everything
- Declarative configuration
- Easy deployment process
- Integrated backup system
- Minimal external dependencies

## Proposed Architecture

### K3s Deployment Model

```
┌─────────────────────────────────────────────┐
│              NixOS Host                      │
│  ┌─────────────────────────────────────┐    │
│  │         K3s Control Plane           │    │
│  └─────────────────────────────────────┘    │
│  ┌─────────────────────────────────────┐    │
│  │    Kubernetes Resources (via Nix)   │    │
│  │  - Deployments                      │    │
│  │  - Services                         │    │
│  │  - ConfigMaps/Secrets              │    │
│  │  - Ingress Rules                   │    │
│  └─────────────────────────────────────┘    │
└─────────────────────────────────────────────┘
```

### Cluster Topology

```
Storage Host (K3s Server)
├── Control Plane
├── Media Services
├── Storage Services
└── Infrastructure

Cloud Host (K3s Agent)
├── Auth Services
├── Public Services
└── Utilities
```

## Implementation Approach

### 1. NixOS K3s Module

```nix
# modules/k3s-cluster.nix
{ config, lib, pkgs, ... }:
{
  # K3s server on storage
  services.k3s = {
    enable = true;
    role = "server";
    serverAddr = "https://storage.bat-boa.ts.net:6443";
    token = config.age.secrets.k3s-token.path;
    
    # Minimal K3s for low overhead
    extraFlags = [
      "--disable traefik"      # We use Caddy
      "--disable servicelb"    # Not needed
      "--disable-cloud-controller"
      "--write-kubeconfig-mode 644"
    ];
  };
  
  # Generate Kubernetes manifests from Nix
  environment.etc = {
    "k3s/manifests" = {
      source = config.kubernetes.generatedManifests;
    };
  };
}
```

### 2. Leveraging Existing Media System Abstraction

**Key Insight**: This infrastructure doesn't use `virtualisation.oci-containers.containers` directly. Instead, it uses the media system abstraction layer (`media.containers`) which generates Podman configurations. This abstraction can be extended to generate Kubernetes manifests instead.

#### Current High-Level Configuration
```nix
# Using the media system abstraction (constellation layer)
constellation.media.enable = true;

# Or direct media container definitions
media.containers.plex = {
  listenPort = 32400;
  mediaVolumes = true;
  network = "host";
  devices = ["/dev/dri:/dev/dri"];
  environment = {
    VERSION = "latest";
  };
};
```

#### Proposed Kubernetes Translation Layer

The existing media system abstraction (`modules/media/containers.nix`) can be extended with a Kubernetes backend:

```nix
# modules/media/kubernetes.nix
{ config, lib, pkgs, ... }:
let
  cfg = config.media.containers;
  mediaConfig = config.media.config;
  
  # Convert media container to Kubernetes deployment
  containerToDeployment = name: container: {
    apiVersion = "apps/v1";
    kind = "Deployment";
    metadata = {
      inherit name;
      namespace = "media";
      labels.app = name;
    };
    spec = {
      replicas = 1;
      selector.matchLabels.app = name;
      template = {
        metadata.labels.app = name;
        spec = {
          containers = [{
            inherit name;
            image = container.image;
            ports = lib.optional (container.listenPort != null) {
              containerPort = container.listenPort;
            };
            env = lib.mapAttrsToList (name: value: {
              inherit name;
              value = toString value;
            }) (container.environment // {
              PUID = toString mediaConfig.puid;
              PGID = toString mediaConfig.pgid;
              TZ = mediaConfig.tz;
            });
            volumeMounts = 
              lib.optional (container.configDir != null) {
                name = "config";
                mountPath = container.configDir;
              } ++ 
              lib.optionals container.mediaVolumes [
                { name = "files"; mountPath = "/files"; }
                { name = "media"; mountPath = "/media"; readOnly = true; }
              ] ++
              map (volume: 
                let parts = lib.splitString ":" volume;
                in {
                  name = "volume-${builtins.hashString "md5" (lib.head parts)}";
                  mountPath = lib.elemAt parts 1;
                  readOnly = lib.length parts > 2 && lib.elemAt parts 2 == "ro";
                }
              ) container.volumes;
            securityContext = lib.optionalAttrs container.privileged {
              privileged = true;
            };
          }];
          volumes = 
            lib.optional (container.configDir != null) {
              name = "config";
              hostPath.path = "${mediaConfig.configDir}/${name}";
            } ++
            lib.optionals container.mediaVolumes [
              { name = "files"; hostPath.path = "${mediaConfig.dataDir}/files"; }
              { name = "media"; hostPath.path = "${mediaConfig.storageDir}/media"; }
            ] ++
            map (volume:
              let parts = lib.splitString ":" volume;
              in {
                name = "volume-${builtins.hashString "md5" (lib.head parts)}";
                hostPath.path = lib.head parts;
              }
            ) container.volumes;
          nodeSelector = {
            "kubernetes.io/hostname" = container.host;
          };
          hostNetwork = container.network == "host";
        };
      };
    };
  };
  
  # Convert to Kubernetes service
  containerToService = name: container: lib.optionalAttrs (container.listenPort != null) {
    apiVersion = "v1";
    kind = "Service";
    metadata = {
      inherit name;
      namespace = "media";
    };
    spec = {
      selector.app = name;
      ports = [{
        port = container.exposePort or (nameToPort name);
        targetPort = container.listenPort;
      }];
      type = if container.network == "host" then "ClusterIP" else "ClusterIP";
    };
  };
in
{
  options.media.kubernetes = {
    enable = lib.mkEnableOption "Kubernetes backend for media containers";
    
    backend = lib.mkOption {
      type = lib.types.enum [ "podman" "kubernetes" ];
      default = "podman";
      description = "Container backend to use";
    };
  };
  
  config = lib.mkIf (config.media.kubernetes.enable && config.media.kubernetes.backend == "kubernetes") {
    # Generate Kubernetes manifests instead of Podman containers
    kubernetes.resources = {
      deployments = lib.mapAttrs containerToDeployment cfg;
      services = lib.mapAttrs containerToService cfg;
    };
    
    # Disable Podman containers when using Kubernetes
    virtualisation.oci-containers.containers = lib.mkForce {};
    
    # Ensure K3s is enabled
    services.k3s.enable = lib.mkDefault true;
  };
}
```

#### Seamless Backend Switching

With this approach, the same high-level service definitions work with both backends:

```nix
# Same configuration works for both Podman and Kubernetes
media.containers = {
  plex = {
    listenPort = 32400;
    mediaVolumes = true;
    network = "host";
    devices = ["/dev/dri:/dev/dri"];
    environment = {
      VERSION = "latest";
    };
  };
  
  jellyfin = {
    listenPort = 8096;
    mediaVolumes = true;
    devices = ["/dev/dri:/dev/dri"];
  };
  
  sonarr = {
    listenPort = 8989;
    mediaVolumes = true;
  };
};

# Switch between backends without changing service definitions
media.kubernetes = {
  enable = true;
  backend = "kubernetes";  # or "podman"
};
```
```

### 3. Nix Kubernetes Module

Create a module to generate K8s manifests from Nix:

```nix
# modules/kubernetes.nix
{ config, lib, pkgs, ... }:
let
  # Convert Nix attrset to YAML
  toYAML = name: attrs: pkgs.writeText "${name}.yaml" 
    (builtins.toJSON attrs);
    
  # Generate all manifests
  manifests = lib.mapAttrsToList (name: resource:
    toYAML name resource
  ) config.kubernetes.resources.all;
in
{
  options.kubernetes = {
    resources = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = {};
    };
  };
  
  config = {
    # Collect all resources
    kubernetes.resources.all = lib.flatten [
      (lib.mapAttrsToList (name: deploy: {
        apiVersion = "apps/v1";
        kind = "Deployment";
        inherit (deploy) metadata spec;
      }) config.kubernetes.resources.deployments)
      
      (lib.mapAttrsToList (name: svc: {
        apiVersion = "v1";
        kind = "Service";
        inherit (svc) metadata spec;
      }) config.kubernetes.resources.services)
    ];
    
    # Generate manifest directory
    kubernetes.generatedManifests = pkgs.linkFarm "k8s-manifests"
      (map (m: { name = baseNameOf m; path = m; }) manifests);
  };
}
```

### 4. Preserving Caddy Flexibility with Kubernetes

**Key Insight**: Instead of replacing Caddy with Kubernetes ingress, we can enhance the existing Caddy setup to proxy to Kubernetes services while maintaining all current functionality.

#### Current Caddy Architecture Benefits
- **Multi-Host Deployment**: Caddy runs on both storage and cloud hosts
- **DNS Magic**: `*.arsfeld.one` → `192.168.1.5` (storage local IP) for home access
- **Tailscale Integration**: Same domains work over Tailscale with different IPs
- **Service Flexibility**: Serves containers, static sites, APIs, file shares, etc.
- **SSL Management**: Automatic certificates with Cloudflare DNS
- **Custom Routing**: Complex routing rules beyond simple container proxying

#### Enhanced Gateway Integration

Instead of Kubernetes ingress, extend the existing gateway system to discover and proxy to Kubernetes services:

```nix
# modules/media/gateway-k8s-enhanced.nix
{ config, lib, ... }:
let
  utils = import "${self}/modules/media/__utils.nix" {inherit config lib;};
  cfg = config.media.gateway;
  k8sCfg = config.media.kubernetes;
  
  # Generate service discovery for K8s services
  discoverK8sServices = {
    # K8s services are accessible via cluster IP from the host
    # Format: <service-name>.<namespace>.svc.cluster.local
    # But we can also use NodePort or host networking
  };
  
  # Enhanced generateHost function that handles both Podman and K8s backends
  generateHostEnhanced = { domain, cfg }:
    let
      # Determine the actual target based on backend
      target = 
        if (config.media.containers.${cfg.name}.enable or false) && 
           k8sCfg.backend == "kubernetes"
        then {
          # K8s service - proxy to cluster IP or NodePort
          host = "127.0.0.1";  # localhost since K8s runs on same host
          port = cfg.port;      # K8s service port (NodePort or exposed port)
        }
        else {
          # Regular service (Podman container, static site, etc.)
          host = cfg.host;
          port = cfg.port;
        };
    in
      utils.generateHost {
        inherit domain;
        cfg = cfg // target;
      };
in
{
  config = lib.mkIf cfg.enable {
    # NO Kubernetes ingress resources - keep using Caddy
    # kubernetes.resources.ingresses = {}; # Explicitly avoid K8s ingress
    
    # Enhanced Caddy configuration that works with both backends
    services.caddy.virtualHosts = utils.generateHosts {
      services = cfg.services;
      domain = cfg.domain;
    };
    
    # Ensure K8s services are exposed via NodePort when using K8s backend
    kubernetes.resources.services = lib.mkIf (k8sCfg.backend == "kubernetes") (
      lib.mapAttrs (name: container: {
        apiVersion = "v1";
        kind = "Service";
        metadata = {
          inherit name;
          namespace = "media";
        };
        spec = {
          type = "NodePort";  # Expose on host IP
          selector.app = name;
          ports = [{
            port = container.listenPort;
            targetPort = container.listenPort;
            nodePort = container.exposePort or (nameToPort name);
          }];
        };
      }) (lib.filterAttrs (n: c: c.enable && c.listenPort != null) config.media.containers)
    );
  };
}
```

#### Kubernetes Service Exposure Strategy

Instead of K8s ingress, use **NodePort services** to expose containers on the host IP:

```nix
# In modules/media/kubernetes.nix
containerToService = name: container: {
  apiVersion = "v1";
  kind = "Service";
  metadata = {
    inherit name;
    namespace = "media";
  };
  spec = {
    type = "NodePort";
    selector.app = name;
    ports = [{
      port = container.listenPort;
      targetPort = container.listenPort;
      nodePort = container.exposePort or (nameToPort name);
    }];
  };
};
```

This means:
- **Kubernetes pods** run inside the cluster
- **NodePort services** expose them on host IPs (storage: 192.168.1.5, cloud: 192.168.1.6)
- **Caddy continues** to proxy to host IPs as it does now
- **Zero change** to DNS, routing, or Caddy configuration

#### Preserved Functionality

✅ **DNS Magic Preserved**:
```bash
# Home network: *.arsfeld.one → 192.168.1.5:port
plex.arsfeld.one → 192.168.1.5:32400 (NodePort)

# Tailscale: *.arsfeld.one → storage.bat-boa.ts.net:port  
plex.arsfeld.one → 100.x.x.x:32400 (NodePort)
```

✅ **Multi-Service Flexibility**:
```nix
services.caddy.virtualHosts = {
  # K8s container via NodePort
  "plex.arsfeld.one" = {
    extraConfig = ''
      reverse_proxy 192.168.1.5:32400
    '';
  };
  
  # Regular Podman container  
  "ghost.arsfeld.one" = {
    extraConfig = ''
      reverse_proxy cloud.bat-boa.ts.net:2368
    '';
  };
  
  # Static file server
  "files.arsfeld.one" = {
    extraConfig = ''
      file_server browse
      root /mnt/storage/files
    '';
  };
  
  # Custom API endpoint
  "api.arsfeld.one" = {
    extraConfig = ''
      reverse_proxy /v1/* backend1.internal:8080
      reverse_proxy /v2/* backend2.internal:9090
    '';
  };
};
```

✅ **Multi-Host Caddy**:
- Storage Caddy: Handles local services + K8s NodePorts
- Cloud Caddy: Handles cloud services + K8s NodePorts  
- Both continue working independently

✅ **Special Network Features Preserved**:
```nix
# Host networking for services that need it (Plex, Stash)
media.containers.plex = {
  network = "host";  # K8s translation: hostNetwork: true
  # Still accessible at storage:32400 directly
};

# Device access for GPU transcoding
media.containers.plex = {
  devices = ["/dev/dri:/dev/dri"];  # K8s translation: device plugins
};

# Privileged containers
media.containers.special-service = {
  privileged = true;  # K8s translation: securityContext.privileged
};
```

#### Architecture Diagram

```
Internet/Home/Tailscale
        ↓
   DNS Magic (*.arsfeld.one → 192.168.1.5)
        ↓
 [192.168.1.5] Storage Host
        ↓
    Caddy (Port 443) - UNCHANGED
    ├── Static Files → /mnt/storage  
    ├── Podman Services → container:port
    ├── K8s NodePorts → localhost:nodeport  
    ├── Host Network K8s → storage:port
    └── External APIs → remote:port
        ↓
   K3s Cluster (if enabled)
   ├── Pod: plex (hostNetwork) → Direct access
   ├── Pod: sonarr → NodePort 8989  
   └── Pod: radarr → NodePort 7878

 [192.168.1.6] Cloud Host  
        ↓
    Caddy (Port 443) - UNCHANGED
    ├── K8s NodePorts → localhost:nodeport
    ├── Podman Services → container:port
    └── Static Sites → /var/www
        ↓
   K3s Agent (if enabled)
   ├── Pod: ghost → NodePort 2368
   └── Pod: yarr → NodePort 7070
```

#### Alternative: K8s Ingress with DNS Magic

**What if we migrate ingress to K8s but preserve DNS magic?** Here's how:

##### Multi-Host K8s Ingress Strategy

```nix
# Both hosts run K8s ingress controllers
# Each responds to the same domains based on DNS routing

# Storage host (192.168.1.5) - handles media services
services.k3s.extraFlags = [
  "--disable traefik"  # We'll use nginx-ingress
];

# Install nginx-ingress on both hosts
kubernetes.resources.ingresses.media-storage = {
  metadata = {
    name = "media-storage";
    annotations = {
      "kubernetes.io/ingress.class" = "nginx";
      "cert-manager.io/cluster-issuer" = "cloudflare";
      # Route only media services to this ingress
      "nginx.ingress.kubernetes.io/server-alias" = "plex.arsfeld.one,sonarr.arsfeld.one,radarr.arsfeld.one";
    };
  };
  spec = {
    tls = [{
      hosts = ["*.arsfeld.one"];
      secretName = "arsfeld-one-tls";
    }];
    rules = [
      {
        host = "plex.arsfeld.one";
        http.paths = [{
          path = "/";
          backend.service = { name = "plex"; port.number = 32400; };
        }];
      }
      # ... other media services
    ];
  };
};

# Cloud host (192.168.1.6) - handles auth/public services  
kubernetes.resources.ingresses.services-cloud = {
  metadata = {
    name = "services-cloud";
    annotations = {
      "kubernetes.io/ingress.class" = "nginx";
      "cert-manager.io/cluster-issuer" = "cloudflare";
      # Route auth/public services to this ingress
      "nginx.ingress.kubernetes.io/server-alias" = "auth.arsfeld.one,blog.arsfeld.one,api.arsfeld.one";
    };
  };
  spec = {
    rules = [
      {
        host = "auth.arsfeld.one";
        http.paths = [{
          path = "/";
          backend.service = { name = "authelia"; port.number = 9091; };
        }];
      }
      # ... other public services
    ];
  };
};
```

##### DNS Magic Preserved

Your current DNS setup continues to work:

```bash
# Home network DNS (router/Pi-hole/etc.)
*.arsfeld.one → 192.168.1.5  # Points to storage by default

# But with intelligent routing:
# Storage nginx-ingress handles: plex.*, sonarr.*, radarr.*, etc.
# Cloud nginx-ingress handles: auth.*, blog.*, api.*, etc.

# Tailscale DNS
*.arsfeld.one → storage.bat-boa.ts.net  # Same concept
```

##### How Multi-Host Ingress Works

```
Internet/Home Network
        ↓
   DNS: *.arsfeld.one → 192.168.1.5
        ↓
┌─────────────────────────────────────────┐
│ [192.168.1.5] Storage Host              │
│                                         │
│ nginx-ingress (Port 443)                │
│ ├── plex.arsfeld.one → K8s service     │
│ ├── sonarr.arsfeld.one → K8s service   │
│ ├── files.arsfeld.one → static files   │
│ └── auth.arsfeld.one → PROXY to cloud  │ ←── Key insight!
└─────────────────────────────────────────┘
        ↓ (for auth services)
┌─────────────────────────────────────────┐
│ [192.168.1.6] Cloud Host               │
│                                         │
│ nginx-ingress (Port 443)                │
│ ├── auth.arsfeld.one → K8s service     │
│ ├── blog.arsfeld.one → K8s service     │
│ └── api.arsfeld.one → K8s service      │
└─────────────────────────────────────────┘
```

##### Enhanced Ingress Configuration

```nix
# modules/media/k8s-ingress.nix
{ config, lib, ... }:
let
  cfg = config.media.gateway;
  
  # Define which services run on which hosts
  storageServices = ["plex" "sonarr" "radarr" "bazarr" "overseerr" "jellyfin"];
  cloudServices = ["authelia" "ghost" "lldap" "keycloak"];
  
  # Generate ingress rules with cross-host proxying
  generateIngressRules = services: hostType:
    map (serviceName: 
      let 
        service = cfg.services.${serviceName};
        isLocalService = builtins.elem serviceName (
          if hostType == "storage" then storageServices else cloudServices
        );
      in {
        host = "${serviceName}.${cfg.domain}";
        http.paths = [{
          path = "/";
          pathType = "Prefix";
          backend = 
            if isLocalService then {
              # Local K8s service
              service = {
                name = serviceName;
                port.number = service.port;
              };
            } else {
              # Proxy to other host
              service = {
                name = "cross-host-proxy";
                port.number = 8080;
              };
            };
        }];
      }
    ) (builtins.attrNames services);
    
  # Cross-host proxy service (nginx upstream)
  crossHostProxy = targetHost: {
    apiVersion = "v1";
    kind = "ConfigMap";
    metadata.name = "nginx-proxy-config";
    data."nginx.conf" = ''
      upstream cross-host {
        server ${targetHost}:443;
      }
      
      server {
        listen 8080;
        location / {
          proxy_pass https://cross-host;
          proxy_ssl_verify off;
          proxy_set_header Host $host;
          proxy_set_header X-Real-IP $remote_addr;
        }
      }
    '';
  };
in
{
  config = lib.mkIf (cfg.enable && config.media.kubernetes.backend == "kubernetes") {
    
    # Install nginx-ingress controller
    kubernetes.resources = {
      
      # Main ingress for this host's services
      ingresses.main = {
        metadata = {
          name = "main-ingress";
          annotations = {
            "kubernetes.io/ingress.class" = "nginx";
            "cert-manager.io/cluster-issuer" = "cloudflare";
            "nginx.ingress.kubernetes.io/ssl-redirect" = "true";
          };
        };
        spec = {
          tls = [{
            hosts = ["*.${cfg.domain}"];
            secretName = "${cfg.domain}-tls";
          }];
          rules = generateIngressRules cfg.services config.networking.hostName;
        };
      };
      
      # Cross-host proxy for services on other hosts
      configMaps.nginx-proxy = crossHostProxy (
        if config.networking.hostName == "storage" 
        then "cloud.bat-boa.ts.net" 
        else "storage.bat-boa.ts.net"
      );
    };
    
    # Still preserve some Caddy functionality for non-container services
    services.caddy.virtualHosts = {
      # Static file servers, custom APIs, etc.
      "files.${cfg.domain}" = {
        extraConfig = ''
          file_server browse
          root /mnt/storage/files
        '';
      };
    };
  };
}
```

#### Benefits of K8s Ingress Approach

✅ **DNS Magic Fully Preserved**:
- Same DNS setup: `*.arsfeld.one → 192.168.1.5`
- Same Tailscale routing
- Cross-host proxying for services on different hosts

✅ **True K8s Native Ingress**:
- Industry-standard ingress controllers
- Better SSL management with cert-manager
- Advanced routing capabilities
- Standardized annotations and features

✅ **Multi-Host Load Distribution**:
```bash
# Storage ingress handles heavy media services
plex.arsfeld.one → storage nginx-ingress → plex pod

# Cloud ingress handles auth/API services  
auth.arsfeld.one → storage nginx-ingress → proxy → cloud nginx-ingress → authelia pod
```

✅ **Hybrid Capability**:
- K8s ingress for containers
- Caddy for static files, custom routing
- Best of both worlds

#### Implementation Strategy

1. **Phase 1**: Install nginx-ingress on both hosts
2. **Phase 2**: Configure cross-host proxying 
3. **Phase 3**: Migrate container ingress to K8s
4. **Phase 4**: Keep Caddy for special cases (static files, complex routing)

This approach gives you **true Kubernetes ingress** while **preserving 100% of your DNS magic and multi-host flexibility**.
```

## Migration Steps with Media System Abstraction

### Phase 1: Preparation (1 week)
1. **Test Environment**: Set up test VMs with K3s
2. **Backend Module Development**: Create `modules/media/kubernetes.nix`
3. **Service Inventory**: All services already defined in `media.containers`
4. **Gateway Integration**: Update gateway system for K8s ingress

### Phase 2: Infrastructure Setup (1 week)
1. **Install K3s on Storage**: Server role with data storage
2. **Install K3s on Cloud**: Agent role joining cluster
3. **Storage Configuration**: Set up persistent volumes
4. **Network Setup**: Configure service mesh

### Phase 3: Seamless Backend Migration (1 week)
Unlike traditional K8s migrations, this approach leverages the existing abstraction:

1. **Enable Kubernetes Backend**:
   ```nix
   # Simply switch the backend in configuration
   media.kubernetes = {
     enable = true;
     backend = "kubernetes";  # was "podman"
   };
   ```

2. **No Service Definition Changes Required**:
   - All 50+ services already defined in `media.containers`
   - Same configuration syntax works for both backends
   - Constellation module (`constellation.media.enable = true`) unchanged

3. **Gradual Migration per Host**:
   ```nix
   # storage/configuration.nix
   media.kubernetes.backend = "kubernetes";
   
   # cloud/configuration.nix  
   media.kubernetes.backend = "podman";  # migrate later
   ```

4. **Per-Service Validation**:
   - Deploy with new backend
   - Verify functionality via existing monitoring
   - Gateway automatically routes traffic
   - Rollback by changing backend option

### Phase 4: Optimization (1 week)
1. **Resource Limits**: Add K8s-specific options to media containers
2. **Health Checks**: Extend container abstraction with health check options
3. **Monitoring**: Integrate with existing Netdata
4. **Backup Integration**: Update backup paths (minimal changes needed)

## Honest Benefits Analysis: K8s vs. Current Setup

Given that the abstraction layer preserves all current functionality while adding K8s underneath, what are the **actual tangible benefits**?

### ✅ **Real Kubernetes Advantages** (for this specific setup)

#### 1. **Resource Management & QoS**
```nix
# Current: No resource limits - services can consume all CPU/RAM
# K8s: Enforceable limits and guarantees
media.containers.plex = {
  resources = {
    requests = { cpu = "2"; memory = "4Gi"; };
    limits = { cpu = "4"; memory = "8Gi"; };
  };
};
```
**Impact**: Prevents runaway services from killing the host. Currently if Plex transcoding goes wild, it can make the entire storage host unresponsive.

#### 2. **Automatic Restarts with Backoff**
```bash
# Current: systemd restarts, but basic policy
# K8s: Sophisticated restart policies with exponential backoff
```
**Impact**: Better handling of flaky services. Some media services (like certain *arr apps) occasionally crash - K8s has smarter restart handling.

#### 3. **Rolling Updates**
```bash
# Current: Service stops → update → service starts (brief downtime)
# K8s: Zero-downtime updates with health checks
```
**Impact**: For critical services, you can update without any downtime.

#### 4. **Multi-Host Failover** (if you add more nodes)
```bash
# Current: If storage host dies, all media services are down
# K8s: Services can migrate to cloud host automatically
```
**Impact**: Currently if your storage host has hardware issues, everything is down until you fix it.

#### 5. **Standardized Tooling**
```bash
# Current: podman ps, systemctl status, journalctl
# K8s: kubectl, universal K8s monitoring/debugging tools
```
**Impact**: Industry-standard tooling, better ecosystem, transferable skills.

### ❌ **Honest Disadvantages**

#### 1. **Significant Resource Overhead**
```bash
# Current: ~100MB overhead for Podman
# K8s: ~1GB overhead for K3s + per-pod overhead
```
**Impact**: On your home infrastructure, this is 10x the overhead for orchestration.

#### 2. **Added Complexity**
```bash
# Current: Simple systemd services, direct troubleshooting
# K8s: Additional abstraction layer, more components to debug
```
**Impact**: When things break, you have more layers to investigate.

#### 3. **Questionable Value for 2-Host Setup**
```bash
# K8s designed for: 10+ nodes, microservices, large teams
# Your setup: 2 hosts, monolithic services, single user
```
**Impact**: You're using enterprise orchestration for a home lab.

### 🤔 **Critical Question: Do You Actually Need These Benefits?**

#### **Resource Management**: 
- **Current state**: Do your services actually consume excessive resources? 
- **K8s benefit**: Only valuable if you have resource contention issues

#### **High Availability**:
- **Current state**: How often do your hosts actually fail?
- **K8s benefit**: Only valuable if downtime is actually a problem for you

#### **Zero-downtime updates**:
- **Current state**: How often do you update services? Is brief downtime acceptable?
- **K8s benefit**: Only valuable if you need 24/7 uptime

#### **Multi-host failover**:
- **Current state**: Do you plan to add more hosts?
- **K8s benefit**: Only valuable with 3+ hosts for meaningful failover

### 📊 **ROI Analysis for Your Specific Setup**

| Benefit | Value to Home Lab | Implementation Cost | Worth It? |
|---------|------------------|-------------------|-----------|
| Resource limits | Low (rarely hit limits) | Medium | ❌ No |
| Auto-restart | Low (systemd works fine) | Low | ❓ Maybe |
| Rolling updates | Low (brief downtime OK) | Medium | ❌ No |
| Failover | None (only 2 hosts) | High | ❌ No |
| Standard tooling | Medium (nice to have) | Low | ❓ Maybe |
| Learning | High (career value) | High | ✅ Yes |

### 🎯 **Realistic Assessment**

**For your 2-host home infrastructure**: The practical benefits of Kubernetes are **minimal**. Your current Podman setup with systemd is actually well-suited for this scale.

**The main real benefits would be**:
1. **Learning K8s** for career/skill development
2. **Future-proofing** if you plan to expand significantly
3. **Standardization** if you work with K8s professionally

**The costs are**:
1. **~1GB RAM overhead** (significant for home lab)
2. **Added complexity** when troubleshooting
3. **Maintenance overhead** of K8s components

### 💡 **Alternative: Enhanced Podman Setup**

Instead of K8s, you could enhance your current setup with:

```nix
# Add resource limits to Podman containers
virtualisation.oci-containers.containers.plex = {
  extraOptions = [
    "--memory=8g"
    "--cpus=4"
    "--restart=unless-stopped"
  ];
};

# Better systemd integration
systemd.services."podman-plex" = {
  serviceConfig = {
    Restart = "always";
    RestartSec = "30s";
  };
};

# Health checks
systemd.timers.container-health = {
  # Custom health checking
};
```

This gives you 80% of K8s benefits with 10% of the complexity.

## Complexity Comparison

### Current Setup
```
Nix → Media Abstraction → Podman → Container
High-level definition, minimal overhead
```

### Proposed K8s Setup
```
Nix → Media Abstraction → K8s Manifest → K8s API → Scheduler → Container Runtime → Container
Same high-level definition, more flexibility, more runtime complexity
```

### Traditional K8s Migration
```
Nix → Podman → Container
         ↓ (manual conversion)
Nix → K8s Manifest → K8s API → Scheduler → Container Runtime → Container
```

### Our Abstraction-Based Migration
```
Nix → Media Abstraction → Podman → Container
         ↓ (backend switch)
Nix → Media Abstraction → K8s Manifest → K8s API → Scheduler → Container Runtime → Container
```

**Key Insight**: The abstraction layer eliminates the need to redefine services, making the migration significantly simpler.

## Resource Overhead

### Current (Podman)
- Podman daemon: ~50MB RAM
- Per container: Native overhead only
- Total overhead: <100MB

### K3s
- Server node: ~512MB RAM
- Agent node: ~256MB RAM
- Per pod: ~50MB overhead
- Total overhead: ~1GB

## Maintaining Simplicity

### 1. **No External Tools**
- No ArgoCD, Flux, or Helm
- Pure Nix for configuration
- Git for version control only

### 2. **Single Repository**
```
nixos/
├── hosts/
│   ├── storage/
│   │   └── k8s-server.nix
│   └── cloud/
│       └── k8s-agent.nix
├── modules/
│   ├── kubernetes/
│   │   ├── services/
│   │   ├── deployments/
│   │   └── ingress/
│   └── k3s-cluster.nix
└── flake.nix
```

### 3. **Simple Deployment**
```bash
# Still works the same way
just deploy storage
just deploy cloud

# New commands
just k8s-status
just k8s-rollout plex
```

## Decision Framework

### Consider K8s If:
- You want industry-standard orchestration
- You need better resource management
- You plan to scale beyond 2 hosts
- You want automatic failover
- Learning K8s is a goal

### Stay with Current If:
- Simplicity is paramount
- Current setup meets all needs
- Resource overhead is a concern
- Migration effort isn't justified
- Podman containers work fine

## Recommended Approach with Abstraction Layer

### Option 1: Abstraction-Powered Migration ⭐ **RECOMMENDED**
1. **Develop Kubernetes Backend**: Create `modules/media/kubernetes.nix`
2. **Test Environment**: Set up K3s cluster with backend switching
3. **Per-Host Migration**: Switch backend independently for each host
4. **Easy Rollback**: Instant rollback by changing backend option
5. **Zero Service Changes**: All existing service definitions work unchanged

Migration process:
```nix
# Week 1: Test on development environment
media.kubernetes = {
  enable = true;
  backend = "kubernetes";
};

# Week 2: Migrate storage host
# hosts/storage/configuration.nix
media.kubernetes.backend = "kubernetes";

# Week 3: Migrate cloud host  
# hosts/cloud/configuration.nix
media.kubernetes.backend = "kubernetes";
```

### Option 2: Hybrid Backend Setup
1. **Run Both Backends**: Some services on K8s, others on Podman
2. **Service-Level Control**: Choose backend per service
3. **Gradual Transition**: Migrate services one by one

```nix
media.containers = {
  plex.kubernetes.backend = "kubernetes";     # K8s
  jellyfin.kubernetes.backend = "podman";     # Podman
  sonarr.kubernetes.backend = "kubernetes";   # K8s
};
```

### Option 3: Enhanced Abstraction Layer
1. **Stay with Podman**: Keep current backend
2. **Enhance Media System**: Add K8s-like features to abstraction
   - Resource limits
   - Health checks  
   - Pod definitions
   - Better service discovery
3. **Get K8s Benefits**: Without K8s complexity

### Option 4: Traditional K8s Migration
1. **Manual Service Conversion**: Rewrite all 50+ service definitions
2. **Learn Kubernetes**: Deep dive into K8s concepts
3. **Full Migration**: Complete switch to K8s paradigm
4. **Highest Effort**: 4-6 weeks of intensive work

## Conclusion

The existing media system abstraction layer **dramatically simplifies** Kubernetes migration compared to traditional approaches. Instead of rewriting 50+ service definitions, you can switch backends with a single configuration option.

### Key Advantages of the Abstraction Approach:

1. **🎯 Zero Service Definition Changes**: All existing `media.containers` and `constellation.media` configurations work unchanged
2. **⚡ Rapid Migration**: 2-3 weeks instead of 4-6 weeks due to elimination of service conversion work  
3. **🛡️ Risk Mitigation**: Instant rollback capability by switching backend option
4. **🔄 Gradual Migration**: Migrate hosts independently at your own pace
5. **🏗️ Preserved Architecture**: Constellation layer and gateway system remain intact

### Revised Honest Recommendation:

After analyzing the real benefits vs. costs for your specific 2-host home infrastructure:

**Primary Value**: The abstraction layer makes Kubernetes migration **technically feasible** and low-risk, but the **practical benefits are minimal** for your setup.

#### **If Your Goal is Learning/Career Development**: ✅ **Go for it**
- The abstraction eliminates migration risk (easy rollback)
- You gain valuable K8s experience
- Future-proofing if you expand significantly
- Low-risk way to experiment with K8s

#### **If Your Goal is Better Infrastructure**: ❌ **Not worth it**
- Current Podman setup is actually well-suited for your scale
- 1GB RAM overhead is significant for home lab
- Added complexity for minimal practical benefit
- Your current setup already provides excellent reliability

#### **Best of Both Worlds**: 🎯 **Enhanced Media Abstraction**
Instead of K8s, enhance your existing media system with K8s-like features:

```nix
# Add to modules/media/containers.nix
media.containers.plex = {
  # Resource limits (translated to Podman options)
  resources = {
    memory = "8Gi";
    cpu = "4";
  };
  
  # Health checks
  healthCheck = {
    command = ["curl", "-f", "http://localhost:32400/health"];
    interval = "30s";
    retries = 3;
  };
  
  # Restart policies
  restart = {
    policy = "unless-stopped";
    backoff = "exponential";
  };
};
```

This approach:
- ✅ Keeps your current simplicity and efficiency
- ✅ Adds K8s-like features to the abstraction
- ✅ Zero resource overhead
- ✅ Maintains all your Caddy flexibility
- ✅ Provides foundation for future K8s migration if needed

**Updated Recommendation**: 
1. **Enhance the current media abstraction** with better resource management, health checks, and restart policies
2. **Keep the K8s backend option** as a future possibility
3. **Only migrate to K8s** if you have specific needs (learning, multi-host expansion, etc.)

The beauty of your abstraction layer is that you can get most K8s benefits by enhancing the Podman backend, while keeping the door open for K8s migration later if your needs change.