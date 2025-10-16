---
id: task-44
title: Enable constellation observability modules on all hosts
status: To Do
assignee: []
created_date: '2025-10-16 17:33'
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
- [ ] #1 observability-hub enabled on storage host
- [ ] #2 metrics-client enabled on all constellation hosts
- [ ] #3 logs-client enabled on all constellation hosts
- [ ] #4 Caddy metrics enabled on storage and cloud
- [ ] #5 All hosts visible in Grafana dashboards
- [ ] #6 Alerts functioning correctly
- [ ] #7 Resource usage is acceptable on all hosts
- [ ] #8 Documentation updated
<!-- AC:END -->
