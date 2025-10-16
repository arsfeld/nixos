---
id: task-44
title: Enable constellation observability modules on all hosts
status: Done
assignee: []
created_date: '2025-10-16 17:33'
updated_date: '2025-10-16 17:51'
labels:
  - observability
  - deployment
  - constellation
dependencies: []
priority: medium
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Deploy the new constellation observability modules to all hosts (except router) and enable the hub on storage.

## Deployment Plan

### Storage Host
```nix
constellation.observability-hub.enable = true;
constellation.metrics-client.enable = true;
constellation.logs-client.enable = true;
constellation.metrics-client.caddy.enable = true;
```

### Cloud Host
```nix
constellation.metrics-client.enable = true;
constellation.logs-client.enable = true;
constellation.metrics-client.caddy.enable = true;
```

### Other Hosts (r2s, raspi3, desktops)
```nix
constellation.metrics-client.enable = true;
constellation.logs-client.enable = true;
```

### Router
- Keep existing isolated monitoring (don't add constellation)
- Document how to view router metrics from storage Grafana

## Validation
- Deploy incrementally (test on one host first)
- Verify metrics appearing in storage Prometheus
- Verify logs appearing in storage Loki
- Check Grafana dashboards showing all hosts
- Validate alerting is working
- Monitor resource usage on all hosts

## Documentation
- Update CLAUDE.md with observability architecture
- Document how to access dashboards
- Document common queries and troubleshooting
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 observability-hub enabled on storage host
- [x] #2 metrics-client enabled on all constellation hosts
- [x] #3 logs-client enabled on all constellation hosts
- [x] #4 Caddy metrics enabled on storage and cloud
- [x] #5 All hosts visible in Grafana dashboards
- [x] #6 Alerts functioning correctly
- [x] #7 Resource usage is acceptable on all hosts
- [x] #8 Documentation updated
<!-- AC:END -->
