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

### 2. Service Definition Translation

Current Podman service:
```nix
virtualisation.oci-containers.containers.plex = {
  image = "plexinc/pms-docker:latest";
  ports = ["32400:32400"];
  volumes = [
    "/mnt/data/plex:/config"
    "/mnt/media:/media"
  ];
  environment = {
    PUID = "1000";
    PGID = "1000";
  };
};
```

Becomes Kubernetes manifest (still in Nix):
```nix
kubernetes.resources.deployments.plex = {
  metadata = {
    name = "plex";
    namespace = "media";
  };
  spec = {
    replicas = 1;
    selector.matchLabels.app = "plex";
    template = {
      metadata.labels.app = "plex";
      spec = {
        containers = [{
          name = "plex";
          image = "plexinc/pms-docker:latest";
          ports = [{
            containerPort = 32400;
          }];
          env = [
            { name = "PUID"; value = "1000"; }
            { name = "PGID"; value = "1000"; }
          ];
          volumeMounts = [
            {
              name = "config";
              mountPath = "/config";
            }
            {
              name = "media";
              mountPath = "/media";
              readOnly = true;
            }
          ];
        }];
        volumes = [
          {
            name = "config";
            hostPath.path = "/mnt/data/plex";
          }
          {
            name = "media";
            hostPath.path = "/mnt/media";
          }
        ];
      };
    };
  };
};
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

### 4. Service Migration Helper

Create a converter for existing services:

```nix
# modules/podman-to-k8s.nix
{ config, lib, ... }:
let
  convertContainer = name: container: {
    deployments.${name} = {
      metadata = {
        inherit name;
        namespace = "default";
      };
      spec = {
        replicas = 1;
        selector.matchLabels.app = name;
        template = {
          metadata.labels.app = name;
          spec = {
            containers = [{
              inherit name;
              inherit (container) image;
              ports = map (p: {
                containerPort = lib.toInt (lib.last (lib.splitString ":" p));
              }) container.ports;
              env = lib.mapAttrsToList (name: value: {
                inherit name value;
              }) container.environment;
              volumeMounts = map (v: 
                let parts = lib.splitString ":" v;
                in {
                  name = "vol-${builtins.hashString "md5" (head parts)}";
                  mountPath = lib.elemAt parts 1;
                  readOnly = lib.length parts > 2 && lib.elemAt parts 2 == "ro";
                }
              ) container.volumes;
            }];
            volumes = map (v:
              let parts = lib.splitString ":" v;
              in {
                name = "vol-${builtins.hashString "md5" (head parts)}";
                hostPath.path = head parts;
              }
            ) container.volumes;
          };
        };
      };
    };
    
    services.${name} = {
      metadata = {
        inherit name;
        namespace = "default";
      };
      spec = {
        selector.app = name;
        ports = map (p:
          let parts = lib.splitString ":" p;
          in {
            port = lib.toInt (head parts);
            targetPort = lib.toInt (lib.last parts);
          }
        ) container.ports;
      };
    };
  };
in
{
  # Auto-convert existing containers
  kubernetes.resources = lib.mkMerge (
    lib.mapAttrsToList convertContainer 
      config.virtualisation.oci-containers.containers
  );
}
```

## Migration Steps

### Phase 1: Preparation (1 week)
1. **Test Environment**: Set up test VMs with K3s
2. **Module Development**: Create Nix K8s modules
3. **Service Inventory**: List all services to migrate
4. **Dependency Mapping**: Identify service dependencies

### Phase 2: Infrastructure Setup (1 week)
1. **Install K3s on Storage**: Server role with data storage
2. **Install K3s on Cloud**: Agent role joining cluster
3. **Storage Configuration**: Set up persistent volumes
4. **Network Setup**: Configure service mesh

### Phase 3: Service Migration (2-3 weeks)
1. **Stateless Services First**: 
   - Web applications
   - API services
   - Media servers (read-only media)

2. **Stateful Services**:
   - Databases (PostgreSQL, Redis)
   - Authentication services
   - File storage services

3. **Per-Service Process**:
   - Convert Podman definition to K8s
   - Test in parallel with existing
   - Migrate traffic via Caddy
   - Verify functionality
   - Remove Podman container

### Phase 4: Optimization (1 week)
1. **Resource Limits**: Set CPU/memory limits
2. **Health Checks**: Configure liveness/readiness
3. **Monitoring**: Integrate with existing Netdata
4. **Backup Integration**: Update backup paths

## Benefits Analysis

### ✅ Advantages

1. **Better Resource Management**
   - CPU/memory limits enforced
   - Automatic pod scheduling
   - Resource sharing between services

2. **Improved Reliability**
   - Automatic container restarts
   - Health check integration
   - Rolling updates

3. **Service Discovery**
   - Built-in DNS for services
   - No more manual port management
   - Simplified inter-service communication

4. **Standardization**
   - Industry-standard orchestration
   - Portable service definitions
   - Better debugging tools

### ❌ Disadvantages

1. **Increased Complexity**
   - Additional abstraction layer
   - More components to manage
   - Steeper learning curve

2. **Resource Overhead**
   - K3s control plane (~512MB RAM)
   - etcd database storage
   - Additional CPU usage

3. **Migration Effort**
   - 4-6 weeks of work
   - Service disruption risk
   - Testing overhead

## Complexity Comparison

### Current Setup
```
Nix → Podman → Container
Simple, direct, minimal overhead
```

### K8s Setup
```
Nix → K8s Manifest → K8s API → Scheduler → Container Runtime → Container
More layers, more flexibility, more complexity
```

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

## Recommended Approach

### Option 1: Incremental Migration
1. Keep core services on Podman
2. Move new services to K8s
3. Gradually migrate over time
4. Maintain hybrid setup

### Option 2: Test Cluster
1. Create separate K3s test environment
2. Mirror some services
3. Compare performance/complexity
4. Make informed decision

### Option 3: Enhanced Podman
1. Stay with current architecture
2. Add Podman features:
   - Systemd integration
   - Pod definitions
   - Health checks
3. Get some K8s benefits without migration

## Conclusion

Migrating to K8s offers better resource management and reliability but adds significant complexity and overhead. For a home infrastructure with 2 hosts and 50+ services, the current Podman setup provides an excellent balance of simplicity and functionality.

**Recommendation**: Stay with the current setup unless you specifically need K8s features. The migration effort (4-6 weeks) and ongoing complexity may not justify the benefits for a personal infrastructure that's already working well.

If you do proceed with K8s, the Nix-based approach outlined here maintains your declarative configuration style while minimizing external dependencies.