---
id: task-45
title: Set up Prometheus federation to pull router metrics into storage
status: To Do
assignee: []
created_date: '2025-10-16 17:33'
labels:
  - observability
  - prometheus
  - federation
  - router
dependencies: []
priority: low
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Configure Prometheus federation so that storage's Prometheus can pull metrics from router's VictoriaMetrics instance, allowing unified visibility without making router part of constellation.

## Implementation
Router keeps its self-contained monitoring (VictoriaMetrics + Grafana + Alertmanager) for reliability and safety, but storage can federate/query those metrics for unified dashboards.

## Options to Consider

### Option 1: Prometheus Federation
Storage Prometheus scrapes router's VictoriaMetrics:
```yaml
scrape_configs:
  - job_name: 'router-federation'
    honor_labels: true
    metrics_path: '/federate'
    params:
      'match[]':
        - '{job="node"}'
        - '{job="blocky"}'
        - '{job="network-metrics"}'
    static_configs:
      - targets: ['router.bat-boa.ts.net:8428']
```

### Option 2: Remote Read
Configure remote_read in Prometheus to query VictoriaMetrics.

### Option 3: Separate Datasource
Just add router's VictoriaMetrics as a separate Grafana datasource (simplest).

## Recommendation
Start with Option 3 (separate datasource), then add Option 1 if unified querying is needed.

## Implementation
- Add router VictoriaMetrics as Grafana datasource
- Create router dashboard in storage Grafana (or link to existing)
- Test queries work from storage
- Document the architecture (router is autonomous, storage observes)
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Router metrics accessible from storage Grafana
- [ ] #2 Router VictoriaMetrics added as Grafana datasource
- [ ] #3 Router dashboards visible in storage Grafana
- [ ] #4 Router maintains its autonomous monitoring setup
- [ ] #5 Federation/remote-read configured if unified querying needed
- [ ] #6 Architecture documented
<!-- AC:END -->
