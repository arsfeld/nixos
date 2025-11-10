---
id: task-142
title: Add Mydia media companion to storage host
status: Done
assignee:
  - Claude
created_date: '2025-11-05 19:35'
updated_date: '2025-11-05 19:58'
labels:
  - storage
  - media
  - container
dependencies: []
priority: medium
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Add mydia (https://github.com/getmydia/mydia) as a containerized service on the storage host. Mydia is a self-hosted media management platform built with Phoenix LiveView that provides unified tracking, monitoring, and automation for TV shows and movies. It integrates with download clients (qBittorrent/Transmission) and indexers (Prowlarr) to automate media acquisition, similar to Sonarr/Radarr but as a single unified application.

This will provide a modern alternative media management interface with real-time updates via LiveView, automated background searching and downloading, and comprehensive media tracking capabilities.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Mydia container is deployed and running on storage host
- [x] #2 Service is accessible via mydia.arsfeld.one through the gateway
- [x] #3 Authentication is configured (either Authelia OIDC or bypassed if mydia has its own auth)
- [x] #4 Secrets are created for SECRET_KEY_BASE and GUARDIAN_SECRET_KEY using sops-nix
- [x] #5 Media library paths are mounted correctly (movies and TV shows from /mnt/storage)
- [x] #6 Container configuration includes necessary environment variables (PHX_HOST, timezone, etc.)
- [x] #7 Service can connect to existing download clients (qbittorrent and/or transmission)
- [x] #8 Service can connect to Prowlarr for indexer integration
- [x] #9 Deployment is tested and service responds successfully
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
## Implementation Plan

Following the `ohdio` Phoenix LiveView pattern from media.nix:

1. Add mydia service to `storageServices` in modules/constellation/media.nix
   - Image: ghcr.io/arsfeld/mydia:latest
   - Port: 4000
   - mediaVolumes = true (auto-mounts /mnt/storage/media)
   - environmentFiles with ragenix secret
   - bypassAuth = true (has own auth + OIDC support)

2. Declare secret in secrets/secrets.nix

3. Generate and encrypt mydia-env.age with ragenix containing:
   - SECRET_KEY_BASE (Phoenix session encryption)
   - GUARDIAN_SECRET_KEY (Guardian JWT auth)

4. Format with just fmt

5. Deploy to storage host

Note: Storage uses ragenix (not sops-nix). Gateway registration is automatic via media.nix.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Deployment successful! Mydia is now running on storage and accessible at https://mydia.arsfeld.one

Service logs show successful startup with adapters registered (download clients, indexers, metadata providers)

Created 6 default quality profiles automatically

Authentication configured with bypassAuth=true (mydia has built-in auth with login page)

Container is using ghcr.io/getmydia/mydia:latest (public image)

Secrets generated and encrypted with ragenix: SECRET_KEY_BASE and GUARDIAN_SECRET_KEY

mediaVolumes=true automatically mounts /mnt/storage/media for TV and Movies

NOTE: Acceptance criteria 7 and 8 (download client and Prowlarr integration) need to be configured through mydia's web UI after initial login

Download client and indexer configuration completed via environment variables

Configured Transmission download client at 192.168.15.1:9091 (DOWNLOAD_CLIENT_1_*)

Configured Prowlarr indexer at http://prowlarr:9696 with API key (INDEXER_1_*)

Verified environment variables are present in container

Download monitoring logs confirm clients are now detected (no more 'No download clients configured' warnings)

Service successfully queries download clients during monitoring cycles
<!-- SECTION:NOTES:END -->
