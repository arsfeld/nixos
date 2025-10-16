---
id: task-42
title: Create unified Grafana dashboards for infrastructure overview
status: Done
assignee: []
created_date: '2025-10-16 17:33'
updated_date: '2025-10-16 17:45'
labels:
  - observability
  - grafana
  - dashboard-design
  - visualization
dependencies: []
priority: medium
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Design and implement beautiful Grafana dashboards for the centralized monitoring system on storage host.

## Dashboards to Create

### 1. Infrastructure Overview (Main Dashboard)
- Topology/service map of all hosts
- Overall health status indicators
- Critical alerts panel
- Resource utilization summary (all hosts)
- Service status grid
- Recent log errors

### 2. Host Dashboard (Template)
- System metrics: CPU, memory, disk, network
- Per-host service status
- Systemd unit health
- Recent logs from the host
- Temperature and hardware sensors
- Uptime and restart history

### 3. Services Dashboard
- Caddy: requests/sec, latency, error rates
- Container metrics (Podman)
- Service-specific panels

## Design Principles
- Follow router dashboard design pattern (excellent example)
- Dark theme
- Color-coded health (green/yellow/red)
- Clear hierarchy with collapsible rows
- Mobile-friendly
- Consistent with router's aesthetic

## Implementation
- Use Grafana provisioning (like router does)
- Create dashboard JSON files
- Auto-provision on observability-hub module
- Make reusable/templated where possible

## Reference
- Port concepts from `/hosts/router/dashboards/`
- Study the excellent panel organization and grid layout
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Infrastructure overview dashboard created and provisioned
- [x] #2 Host template dashboard created for per-host views
- [x] #3 Services dashboard created for service-specific metrics
- [x] #4 Dashboards follow design principles: clean, dark theme, intuitive
- [x] #5 Dashboard JSON files auto-provisioned in observability-hub module
- [x] #6 Dashboards are responsive and well-organized
<!-- AC:END -->
