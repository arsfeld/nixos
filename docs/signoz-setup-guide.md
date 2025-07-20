# SigNoz Setup Guide for NixOS

This guide documents the process of setting up SigNoz observability platform on NixOS using Podman containers with native NixOS services for ClickHouse and ZooKeeper.

## Overview

SigNoz is an open-source observability platform that provides distributed tracing, metrics, and logs in a single pane of glass. This guide covers setting it up using a hybrid approach: Podman containers for SigNoz-specific components and native NixOS services for the infrastructure.

**Strategy**: Hybrid deployment using:
- Native NixOS services for ClickHouse and ZooKeeper
- Podman containers for SigNoz Query Service, Frontend, and OTEL Collector
- Declarative NixOS configuration for all components

## Architecture

The SigNoz setup consists of:
- **ClickHouse**: Time-series database (NixOS service)
- **ZooKeeper**: Coordination service for ClickHouse (NixOS service)
- **Query Service**: Go backend that handles API requests (Podman container)
- **Frontend**: React application for the web UI (Podman container)
- **OpenTelemetry Collector**: Ingests and processes telemetry data (Podman container)
- **Alertmanager**: Handles alerts and notifications (existing NixOS service)

### Official Docker Compose Configuration

The official SigNoz Docker Compose deployment includes these services:

1. **init-clickhouse**: Initializes ClickHouse with histogram quantile binary
2. **zookeeper-1**: Bitnami Zookeeper for coordination
3. **clickhouse**: ClickHouse server with custom configurations
4. **signoz**: Query service backend (port 8080)
5. **signoz-frontend**: React UI (port 3301)
6. **otel-collector**: OpenTelemetry collector (ports 4317/4318)
7. **schema-migrator-sync/async**: Database schema migration services

Our NixOS implementation maintains service parity but uses:
- Native NixOS services for infrastructure (ClickHouse, ZooKeeper)
- Podman containers for SigNoz-specific components
- Systemd for service management and dependencies

## Migration Status

### Previous Approach (Source-based)

We initially attempted to package SigNoz components from source:
- **Packages created** (keeping for potential future use):
  - `/packages/signoz-query-service/default.nix` - Go backend service
  - `/packages/signoz-frontend/default.nix` - Frontend from release tarball
  - `/packages/signoz-schema-migrator/default.nix` - Schema migration tool
  - `/packages/signoz-clickhouse-schema/default.nix` - Schema initialization
  - `/packages/signoz-otel-collector/default.nix` - OTEL collector

- **Issues encountered**:
  - Port conflicts between Query Service and Prometheus
  - Schema field name mismatches (TraceId vs traceID)
  - Complex cluster configuration requirements
  - Difficulty maintaining compatibility with upstream changes

### New Approach (Podman-based)

Following the official Docker deployment guide, we're switching to:
- **Podman containers** for SigNoz-specific components
- **Native NixOS services** for infrastructure (ClickHouse, ZooKeeper)
- **Declarative configuration** using `virtualisation.oci-containers`

Benefits:
- Easier maintenance and updates
- Better compatibility with upstream
- Simplified configuration
- Automatic image updates via Podman module

## Setup Instructions

### Step 1: Enable Podman

Add to your router configuration:
```nix
{
  constellation.podman.enable = true;
}
```

### Step 2: Configure Native Services

The following services will run as native NixOS services:

1. **ClickHouse** - Already configured in your router
2. **ZooKeeper** - Needs to be added for ClickHouse coordination

### Step 3: Configure SigNoz Containers

The SigNoz containers have been configured in `/hosts/router/services/signoz-podman.nix` with:
- Query Service backend on port 8080
- Frontend UI on port 3301
- OTEL Collector on ports 4317 (gRPC) and 4318 (HTTP)
- Schema migrator for initial setup
- ZooKeeper and ClickHouse as native NixOS services

### Step 4: Deploy

Deploy the configuration:
```bash
just deploy router
```

**Note**: The deployment will:
1. Enable Podman container runtime
2. Start ZooKeeper and configure ClickHouse
3. Pull and start SigNoz containers
4. Run schema migration automatically

### Step 5: Verify Services

Check container status:
```bash
ssh root@router.bat-boa.ts.net podman ps
```

Check native service status:
```bash
ssh root@router.bat-boa.ts.net systemctl status clickhouse zookeeper
```

Verify schema migration:
```bash
ssh root@router.bat-boa.ts.net podman logs signoz-schema-migrator
```

### Step 6: Initial Setup

After deployment:
1. Wait 2-3 minutes for all services to initialize
2. Access the web UI at http://router.bat-boa.ts.net:3301
3. The first load may take time as schema is created
4. Default credentials are created on first access

## Access Points

- **OTLP gRPC**: router.bat-boa.ts.net:4317 (for sending telemetry data)
- **OTLP HTTP**: router.bat-boa.ts.net:4318 (for sending telemetry data)

**Note**: The Query Service API and Web UI ports (8080 and 3301) are currently not accessible due to host networking configuration. The service is running but needs additional configuration to expose these ports properly when using host networking mode.

## Configuration Details

### Container Configuration

The Podman containers are managed declaratively through NixOS:
- **Automatic updates**: Daily image pulls with smart container restarts
- **Docker compatibility**: Full Docker API compatibility via Podman
- **Network mode**: Using host networking for easy service discovery

#### Service Dependencies and Configuration

Based on the official Docker Compose, our configuration implements:

1. **Query Service** (`signoz-query-service`):
   - Image: `signoz/query-service:v0.90.1`
   - Port: 8080
   - Environment variables:
     - `ClickHouseUrl`: tcp://localhost:9000
     - `STORAGE`: clickhouse
     - `GODEBUG`: netdns=go
     - `TELEMETRY_ENABLED`: false
     - `DEPLOYMENT_TYPE`: docker-standalone
     - `ZOOKEEPER_SERVERS`: localhost:2181
   - Depends on: OTEL Collector

2. **Frontend** (`signoz-frontend`):
   - Image: `signoz/frontend:v0.90.1`
   - Port: 3301
   - Environment variables:
     - `FRONTEND_API_URL`: http://localhost:8080
     - `SERVER_API_URL`: http://localhost:8080
   - Depends on: Query Service

3. **OTEL Collector** (`signoz-otel-collector`):
   - Image: `signoz/signoz-otel-collector:v0.128.2`
   - Ports: 4317 (gRPC), 4318 (HTTP)
   - Configuration: Custom YAML with receivers, processors, and exporters
   - Environment variables:
     - `OTEL_RESOURCE_ATTRIBUTES`: host.name=router,os.type=linux
     - `DOCKER_MULTI_NODE_CLUSTER`: false

4. **Schema Migration**:
   - Implemented as systemd oneshot service `signoz-schema-init`
   - Uses `signoz/signoz-schema-migrator:v0.128.2`
   - Runs before containers start
   - Checks for existing schema to avoid re-initialization

### Required Configuration Files

1. **OTEL Collector Config** (`/etc/otel-collector/config.yaml`):
```yaml
receivers:
  otlp:
    protocols:
      grpc:
        endpoint: 0.0.0.0:4317
      http:
        endpoint: 0.0.0.0:4318
  prometheus:
    config:
      scrape_configs:
        - job_name: 'node'
          static_configs:
            - targets: ['localhost:9100']

processors:
  batch:
    send_batch_size: 10000
    timeout: 10s
  memory_limiter:
    check_interval: 1s
    limit_mib: 1000
    spike_limit_mib: 200

exporters:
  clickhousetraces:
    datasource: tcp://localhost:9000
  clickhousemetricswrite:
    endpoint: tcp://localhost:9000
    resource_to_telemetry_conversion:
      enabled: true
  clickhouselogsexporter:
    datasource: tcp://localhost:9000

service:
  pipelines:
    traces:
      receivers: [otlp]
      processors: [batch]
      exporters: [clickhousetraces]
    metrics:
      receivers: [otlp, prometheus]
      processors: [batch]
      exporters: [clickhousemetricswrite]
    logs:
      receivers: [otlp]
      processors: [batch]
      exporters: [clickhouselogsexporter]
```

### ClickHouse Schema

The schema will be automatically created by the SigNoz containers on first run.

### Integration with Existing Monitoring

SigNoz runs alongside existing monitoring:
- Grafana/Prometheus continue to operate independently
- Both can scrape from the same exporters
- Caddy can provide unified routing if needed

## Troubleshooting

### Container Issues

Check container logs:
```bash
# View all containers
podman ps -a

# Check logs
podman logs signoz-query-service
podman logs signoz-frontend
podman logs signoz-otel-collector
```

### Common Issues

1. **Container connectivity**:
   - Ensure host networking is working
   - Check firewall rules for required ports

2. **ClickHouse connection**:
   - Verify ClickHouse is listening on localhost:9000
   - Check authentication if enabled

3. **Schema initialization**:
   - Containers will create schema on first run
   - Check container logs for errors

4. **OTEL Collector Configuration**:
   - The collector is sensitive to invalid configuration fields
   - Error: "has invalid keys: migrations" - remove any unsupported fields
   - Check logs with: `journalctl -u podman-signoz-otel-collector -f`

5. **Image Version Issues**:
   - SigNoz uses v-prefixed tags (e.g., v0.90.1, not 0.90.1)
   - Latest stable: v0.90.1 for query-service and frontend
   - OTEL Collector: v0.128.2

### Debugging Podman Configuration

1. **Check container status**:
   ```bash
   ssh root@router.bat-boa.ts.net
   podman ps -a
   systemctl status podman-signoz-*
   ```

2. **View container logs**:
   ```bash
   # Individual container logs
   podman logs signoz-query-service
   podman logs signoz-frontend
   podman logs signoz-otel-collector
   
   # Systemd service logs
   journalctl -u podman-signoz-query-service -f
   journalctl -u podman-signoz-frontend -f
   journalctl -u podman-signoz-otel-collector -f
   ```

3. **Test connectivity**:
   ```bash
   # Test ClickHouse connection
   clickhouse-client -q "SELECT 1"
   
   # Test Query Service API
   curl http://localhost:8080/api/v1/version
   
   # Test Frontend
   curl http://localhost:3301
   
   # Test OTLP endpoints
   curl http://localhost:4318/v1/traces
   ```

4. **Common deployment issues**:
   - **Email notifications**: If systemd email notifications are configured, container failures may trigger emails
   - **Port conflicts**: Ensure no other services are using ports 8080, 3301, 4317, 4318
   - **Network issues**: Host networking mode requires proper localhost resolution
   - **Schema migration**: Check `systemctl status signoz-schema-init` for initialization errors

## Next Steps

1. **Immediate Tasks**
   - Fix remaining deployment issues (email service notifications)
   - Verify all containers start successfully
   - Test OTLP ingestion endpoints

2. **Production Hardening**
   - Configure resource limits for containers
   - Set up persistent volumes if needed
   - Configure authentication
   - Set retention policies

3. **Integration**
   - Configure applications to send telemetry
   - Set up log forwarding from systemd journals
   - Create custom dashboards in SigNoz UI
   - Integrate with existing Prometheus exporters

## Migration Progress

- ✅ Guide updated with Podman strategy
- ✅ Enable Podman on router (constellation.podman.enable = true)
- ✅ Create signoz-podman.nix with all container definitions
- ✅ Configure ZooKeeper and ClickHouse in signoz-podman.nix
- ✅ Update router services.nix to use new configuration
- ✅ Fixed OTEL collector configuration (removed invalid 'migrations' field)
- ✅ Updated container image tags to use v-prefix (e.g., v0.90.1)
- ⏳ Deploy and test - containers pulling successfully, working on final configuration

## Benefits of Podman Approach

1. **Simplified Maintenance**: Use official Docker images
2. **Automatic Updates**: Podman module handles image updates
3. **Better Compatibility**: Follows official deployment patterns
4. **Easier Troubleshooting**: Standard container debugging tools

## Resources

- [SigNoz Docker Installation](https://signoz.io/docs/install/docker/)
- [Podman Documentation](https://podman.io/docs)
- [NixOS Container Options](https://nixos.org/manual/nixos/stable/#ch-containers)

## Files Created/Modified

- ✅ `/hosts/router/services/signoz-podman.nix` - Podman container definitions with native services
- ✅ `/hosts/router/configuration.nix` - Added `constellation.podman.enable = true`
- ✅ `/hosts/router/services.nix` - Switched from signoz-real.nix to signoz-podman.nix
- ✅ OTEL collector configuration embedded in signoz-podman.nix as Nix string

## Current Status

**SigNoz deployment is temporarily disabled** while troubleshooting port exposure issues with host networking mode.

### What's Working:
- ✅ OTEL Collector container starts successfully
- ✅ Query Service container (with bundled frontend) starts successfully
- ✅ ClickHouse and ZooKeeper services are operational
- ✅ Schema migration completed
- ✅ Container configuration matches official Docker Compose

### Issues to Resolve:
1. **Port Exposure Problem**: When using host networking mode, the Query Service doesn't expose ports 8080 (API) and 3301 (Web UI)
2. **Port Conflict**: ZooKeeper appears to be using port 8080, conflicting with Query Service

### Temporary Solution:
- SigNoz is disabled in `/hosts/router/services.nix`
- Prometheus and Grafana continue to provide monitoring on their default ports
- Configuration preserved in `signoz-podman.nix` for future troubleshooting

### Next Steps:
1. Investigate why ports aren't exposed with host networking
2. Consider switching to bridge networking with explicit port mappings
3. Resolve port 8080 conflict between ZooKeeper and Query Service
4. Test with different container network configurations