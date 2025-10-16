---
id: task-37
title: Review observability stack and design centralized monitoring system
status: In Progress
assignee: []
created_date: '2025-10-16 17:17'
updated_date: '2025-10-16 17:34'
labels:
  - observability
  - monitoring
  - grafana
  - prometheus
  - loki
  - dashboard-design
dependencies: []
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
## Problem

Currently, observability and monitoring are fragmented across the infrastructure. We need a comprehensive, centralized monitoring solution where the storage host aggregates metrics and logs from all systems, with a beautifully designed Grafana dashboard for visualization.

## Current State

- Grafana is running on storage host
- Netdata is available but not centrally aggregated
- No centralized log collection system
- Monitoring coverage is incomplete across hosts (storage, cloud, router, r2s, etc.)
- No unified dashboard for infrastructure overview

## Goal

Design and implement a comprehensive observability stack where:
1. Storage host acts as the central monitoring hub
2. All hosts (storage, cloud, router, r2s, raspi3, desktops) ship metrics and logs to storage
3. Beautiful, well-designed Grafana dashboards provide clear visibility
4. System is maintainable and scalable

## Research Needed

### Metrics Collection Options
- **Prometheus**: Industry standard, powerful querying, good for metrics
- **VictoriaMetrics**: Prometheus-compatible, more efficient storage
- **InfluxDB**: Time-series database, alternative to Prometheus

### Log Aggregation Options
- **Loki**: Designed to work with Grafana, lightweight, label-based
- **Elasticsearch**: Powerful but resource-heavy
- **Vector**: High-performance, can ship to multiple destinations

### Exporters & Agents
- **Node Exporter**: System metrics (CPU, memory, disk, network)
- **Caddy metrics**: Built-in Prometheus endpoint
- **Systemd exporter**: Service health and status
- **NixOS-specific exporters**: Nix store, builds, etc.
- **Promtail/Vector**: Log shipping agents

### Dashboard Design
- Review existing Grafana dashboard templates
- Identify key metrics for each host type (server, router, desktop)
- Design hierarchical view (overview → per-host → per-service)
- Include alerting indicators and health status

## Recommended Architecture

**Metrics Path**:
```
All Hosts → (Node Exporter) → Prometheus (storage) → Grafana (storage)
```

**Logs Path**:
```
All Hosts → (Promtail/Vector) → Loki (storage) → Grafana (storage)
```

**Benefits**:
- Loki + Prometheus + Grafana = Single stack, well-integrated
- Prometheus is mature and widely adopted
- Loki is designed for logs with similar query language to Prometheus
- Both work seamlessly with Grafana
- Relatively lightweight compared to ELK stack

## Dashboard Design Goals

1. **Overview Dashboard**:
   - Infrastructure map/topology
   - Overall health status
   - Resource utilization summary
   - Recent alerts and issues

2. **Per-Host Dashboards**:
   - CPU, memory, disk, network graphs
   - Service status and health
   - Recent logs and errors
   - System uptime and restarts

3. **Per-Service Dashboards**:
   - Caddy: Request rates, response times, error rates
   - NixOS: Build status, store size, garbage collection
   - Containers: Podman/container metrics
   - Database/storage services: Query performance, connections

4. **Design Principles**:
   - Clean, modern layout
   - Dark theme (easier on eyes)
   - Color-coded health indicators (green/yellow/red)
   - Clear hierarchy and navigation
   - Mobile-friendly responsive design
   - Consistent styling across all dashboards

## Implementation Considerations

- NixOS modules for exporters are well-supported
- Consider retention policies for metrics and logs
- Plan for disk space usage on storage host
- Ensure monitoring doesn't significantly impact system performance
- Set up alerting rules for critical issues
- Document query patterns and common troubleshooting workflows
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Observability stack architecture documented (metrics, logs, visualization)
- [ ] #2 Prometheus or VictoriaMetrics deployed on storage host collecting metrics from all systems
- [ ] #3 Loki deployed on storage host collecting logs from all systems
- [ ] #4 Node exporters deployed on all hosts (storage, cloud, router, r2s, raspi3)
- [ ] #5 Service-specific exporters configured (Caddy, systemd, NixOS)
- [ ] #6 Grafana dashboards designed and deployed (overview, per-host, per-service)
- [ ] #7 Dashboards follow design principles: clean, modern, intuitive navigation
- [ ] #8 Alerting rules configured for critical metrics (disk space, CPU, memory, service down)
- [ ] #9 Retention policies configured for metrics and logs
- [ ] #10 Documentation created for dashboard usage and common queries
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
## Current Analysis Complete

### Existing Setup
- **Storage**: Has Prometheus, Loki, Grafana but only monitoring itself
- **Router**: Mature isolated stack (VictoriaMetrics, Loki, Grafana, Alertmanager, excellent dashboards)
- **Other hosts**: Only have Netdata clients, no metrics/log shipping

### Architecture Designed
Central hub on storage with constellation modules for easy opt-in/out:
- `constellation.metrics-client` - Node exporter on all hosts
- `constellation.logs-client` - Promtail shipping to storage Loki
- `constellation.observability-hub` - Central Prometheus/Loki/Grafana/Alertmanager on storage
- Router keeps autonomous monitoring (safety), but federated into storage

### Implementation Tasks Created
- task-38: metrics-client module (HIGH)
- task-39: logs-client module (HIGH)  
- task-40: observability-hub module (HIGH)
- task-41: Caddy metrics integration (MEDIUM)
- task-42: Unified dashboards (MEDIUM)
- task-43: Centralized alerting (MEDIUM)
- task-44: Deploy to all hosts (MEDIUM)
- task-45: Router federation (LOW)

## Next Steps
1. Start with task-38 (metrics-client module)
2. Then task-39 (logs-client module)
3. Then task-40 (observability-hub module)
4. Test on storage first, then roll out to other hosts
<!-- SECTION:NOTES:END -->
