---
id: task-38
title: Create constellation.metrics-client module for Prometheus node exporter
status: Done
assignee: []
created_date: '2025-10-16 17:33'
updated_date: '2025-10-16 17:40'
labels:
  - observability
  - prometheus
  - constellation
dependencies: []
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Create a new constellation module that deploys Prometheus node exporter on hosts and exposes metrics for the central Prometheus server on storage to scrape.

## Module Design
- Path: `modules/constellation/metrics-client.nix`
- Default: enabled on all constellation hosts
- Exposes node exporter on port 9100 (or configurable)
- Includes systemd, filesystem, network, CPU, memory collectors
- Opens firewall only to Tailscale interface
- Should be lightweight and low-overhead

## Configuration Options
```nix
constellation.metrics-client = {
  enable = true;  # default
  port = 9100;
  openFirewall = true;
  collectors = [ ... ];  # with sensible defaults
}
```

## Reference
- Look at `/hosts/router/services/monitoring.nix` for exporter configuration examples
- Follow pattern from `modules/constellation/netdata-client.nix`
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Module file created at modules/constellation/metrics-client.nix
- [ ] #2 Module enables node exporter with comprehensive collectors
- [ ] #3 Firewall configured to allow scraping from storage host
- [ ] #4 Module follows constellation pattern with enable option
- [ ] #5 Default configuration is lightweight and performant
<!-- AC:END -->
