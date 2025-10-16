---
id: task-40
title: Create constellation.observability-hub module for central monitoring
status: Done
assignee: []
created_date: '2025-10-16 17:33'
updated_date: '2025-10-16 17:43'
labels:
  - observability
  - prometheus
  - loki
  - grafana
  - constellation
dependencies: []
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Create a constellation module for the central observability hub that runs on storage host. This consolidates and extends the existing metrics.nix configuration.

## Module Design
- Path: `modules/constellation/observability-hub.nix`
- Only enabled on storage host
- Runs Prometheus (with federation), Loki, Grafana, Alertmanager
- Configures Prometheus to scrape all constellation hosts
- Sets up retention policies for metrics and logs
- Provisions datasources in Grafana

## Features
- Auto-discover constellation hosts for scraping
- Pull router VictoriaMetrics metrics via remote_read or federation
- Configure alerting rules
- Set retention: 30 days metrics, 14 days logs (configurable)
- Integrate with existing Grafana OAuth setup

## Configuration Options
```nix
constellation.observability-hub = {
  enable = true;  # only on storage
  prometheus = {
    retention = "30d";
    scrapeInterval = "30s";
  };
  loki = {
    retention = "14d";
  };
  alerting = {
    enable = true;
    ntfyUrl = ...;
  };
}
```

## Reference
- Consolidate existing `/hosts/storage/services/metrics.nix`
- Import concepts from `/hosts/router/alerting.nix`
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Module created at modules/constellation/observability-hub.nix
- [x] #2 Prometheus configured to scrape all hosts with metrics-client enabled
- [x] #3 Loki accepting logs from all hosts
- [x] #4 Grafana provisioned with Prometheus and Loki datasources
- [x] #5 Retention policies configured
- [x] #6 Alertmanager configured for critical alerts
<!-- AC:END -->
