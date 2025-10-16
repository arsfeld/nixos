---
id: task-39
title: Create constellation.logs-client module for Promtail log shipping
status: Done
assignee: []
created_date: '2025-10-16 17:33'
updated_date: '2025-10-16 17:42'
labels:
  - observability
  - loki
  - logs
  - constellation
dependencies: []
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Create a constellation module that deploys Promtail to ship systemd journal logs to the central Loki instance on storage host.

## Module Design
- Path: `modules/constellation/logs-client.nix`
- Default: enabled on all constellation hosts
- Ships systemd journal logs to storage:3030
- Labels logs with hostname and systemd unit
- Filters out debug/verbose logs to reduce volume
- Lightweight and minimal resource usage

## Configuration Options
```nix
constellation.logs-client = {
  enable = true;  # default
  lokiUrl = "http://storage:3030";  # configurable
  filterDebugLogs = true;
  maxAge = "12h";
}
```

## Reference
- Look at `/hosts/router/services/log-monitoring.nix` for Promtail config
- Look at `/hosts/storage/services/metrics.nix` for Promtail setup
- Follow constellation pattern
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Module file created at modules/constellation/logs-client.nix
- [x] #2 Promtail configured to ship journal logs to storage Loki
- [x] #3 Logs properly labeled with hostname and unit
- [x] #4 Debug logs filtered to reduce volume
- [x] #5 Module follows constellation enable pattern
<!-- AC:END -->
