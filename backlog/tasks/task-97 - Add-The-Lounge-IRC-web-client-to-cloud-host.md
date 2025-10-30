---
id: task-97
title: Add The Lounge IRC web client to cloud host
status: Done
assignee: []
created_date: '2025-10-28 18:22'
updated_date: '2025-10-28 18:40'
labels:
  - enhancement
  - cloud
  - media-stack
  - container
dependencies: []
priority: medium
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Add The Lounge (https://thelounge.chat/) as a containerized service on the cloud host. The Lounge is a modern, self-hosted web IRC client that allows persistent IRC connections through a web interface.

## Implementation Details

The service should be added to `modules/constellation/media.nix` in the `cloudServices` section, following the existing pattern for containerized services.

**Key Configuration Requirements:**
- Docker image: `thelounge/thelounge:latest`
- Default port: 9000
- Persistent storage needed for user data, logs, and IRC connection state
- Has built-in authentication system (users are managed within The Lounge)
- Should be accessible via gateway at `thelounge.arsfeld.one`

**Gateway Integration:**
The service will automatically integrate with `modules/media/gateway.nix` once added to media.containers, similar to other services like Jellyfin, Overseerr, etc.

**Security Considerations:**
- Service has its own authentication → set `bypassAuth = true` in settings
- Consider enabling `funnel = true` for public access (useful for accessing IRC from anywhere)
- Alternatively, keep funnel disabled for Tailscale-only access

**Storage Location:**
Use `${vars.configDir}/thelounge:/var/opt/thelounge` for persistent data storage (configDir defaults to `/var/data` on cloud). Do NOT use `storageDir` as cloud host doesn't have the `/mnt/storage` mount - that's only for large media files on storage host.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 The Lounge service is added to cloudServices in modules/constellation/media.nix
- [x] #2 Service configuration includes proper image, port (9000), and volume mounts
- [x] #3 Service has bypassAuth = true in settings (has built-in auth)
- [x] #4 Service is accessible via thelounge.arsfeld.one after deploying to cloud host
- [x] #5 Persistent storage is configured for user data and IRC connection state
- [x] #6 Service integrates properly with the media gateway (no manual gateway.nix changes needed)
- [x] #7 Configuration follows existing cloudServices patterns (similar to other services)
- [x] #8 Code is formatted with 'just fmt' before deployment
<!-- AC:END -->
