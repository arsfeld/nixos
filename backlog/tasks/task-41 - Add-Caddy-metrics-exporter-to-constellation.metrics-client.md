---
id: task-41
title: Add Caddy metrics exporter to constellation.metrics-client
status: Done
assignee: []
created_date: '2025-10-16 17:33'
updated_date: '2025-10-16 17:43'
labels:
  - observability
  - caddy
  - metrics
  - constellation
dependencies: []
priority: medium
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Extend the constellation.metrics-client module to optionally enable Caddy's built-in Prometheus metrics endpoint.

## Implementation
- Caddy has native Prometheus metrics support
- Add option: `constellation.metrics-client.caddy.enable`
- Configure Caddy to expose metrics endpoint
- Add to Prometheus scrape config with appropriate job_name
- Only enable on hosts running Caddy (storage, cloud)

## Caddy Config
Caddy exposes metrics via admin API or dedicated metrics endpoint:
```
:2019 {
    metrics /metrics
}
```

## Reference
- Caddy docs: https://caddyserver.com/docs/metrics
- Check existing Caddy configs in `modules/media/gateway.nix`
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Caddy metrics endpoint configured when option enabled
- [x] #2 Prometheus scrapes Caddy metrics from hosts with Caddy running
- [x] #3 Metrics include request rates, response times, status codes
- [x] #4 Integration tested on storage and cloud hosts
<!-- AC:END -->
