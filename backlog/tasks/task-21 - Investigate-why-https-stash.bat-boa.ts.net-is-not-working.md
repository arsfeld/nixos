---
id: task-21
title: 'Investigate why https://stash.bat-boa.ts.net is not working'
status: In Progress
assignee: []
created_date: '2025-10-16 02:50'
updated_date: '2025-10-16 02:51'
labels: []
dependencies: []
priority: medium
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
The stash service on the Tailscale network (https://stash.bat-boa.ts.net) is not responding or accessible. Need to investigate the root cause and fix the issue.

Possible areas to check:
- Service status on the host (likely storage or cloud)
- Tailscale configuration and connectivity
- Caddy/tsnsrv reverse proxy configuration
- Container/service health if running in Podman
- Network firewall rules
- SSL/TLS certificate issues
<!-- SECTION:DESCRIPTION:END -->
