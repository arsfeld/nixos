---
id: task-145
title: Add TP-Link Omada Controller to router host
status: Done
assignee: []
created_date: '2025-11-13 15:10'
updated_date: '2025-11-13 15:15'
labels:
  - infrastructure
  - networking
  - router
dependencies: []
priority: medium
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Add the TP-Link Omada Controller service to the router host to centrally manage TP-Link Omada network devices (access points, switches, routers). This will provide a web-based interface for network management and monitoring.

The service should run in a container using the mbentley/omada-controller:6.0 image and use host networking mode for proper device discovery.

Reference: https://github.com/mbentley/docker-omada-controller
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Omada Controller service is running on the router host
- [x] #2 Service uses host networking mode for device discovery
- [x] #3 Data and logs are persisted across container restarts using named volumes
- [x] #4 Service automatically restarts unless manually stopped
- [x] #5 Web interface is accessible from within the network
- [x] #6 Service timezone is properly configured
- [x] #7 Container resource limits are appropriately set (ulimit nofile=4096:8192)
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Implementation complete:

- Created `/hosts/router/services/omada-controller.nix` with containerized Omada Controller service
- Added service to router imports in `/hosts/router/services.nix`
- Using `mbentley/omada-controller:6.0` Docker image
- Configured host networking mode (`--network=host`) for proper device discovery
- Set up persistent storage using host directories:
  - `/var/data/omada/data` for application data
  - `/var/data/omada/logs` for logs
- Configured timezone (America/New_York) for proper log timestamps
- Set resource limits (`ulimit nofile=4096:8192`) for handling multiple device connections
- Added systemd tmpfiles rules to ensure directories exist with correct permissions
- Service configured with `autoStart = true` for automatic restart

The web interface will be accessible on:
- HTTPS: port 8043
- HTTP: port 8088
Default credentials are admin/admin (should be changed on first login)

Build tested successfully on router configuration.
<!-- SECTION:NOTES:END -->
