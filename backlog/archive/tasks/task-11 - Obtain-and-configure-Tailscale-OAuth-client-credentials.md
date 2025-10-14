---
id: task-11
title: Obtain and configure Tailscale OAuth client credentials
status: To Do
assignee: []
created_date: '2025-10-12 16:40'
labels:
  - infrastructure
  - security
dependencies: []
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Get OAuth client ID and secret from Tailscale admin console and update tailscale-env.age to include TS_API_CLIENT_ID and TS_API_CLIENT_SECRET for Caddy OAuth authentication.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Access Tailscale admin console OAuth section
- [ ] #2 Create OAuth client for Caddy (or verify existing client)
- [ ] #3 Note OAuth client ID and client secret
- [ ] #4 Update tailscale-env.age to include TS_API_CLIENT_ID=<client-id>
- [ ] #5 Update tailscale-env.age to include TS_API_CLIENT_SECRET=<secret>
- [ ] #6 Verify secret file is properly encrypted with ragenix
<!-- AC:END -->
