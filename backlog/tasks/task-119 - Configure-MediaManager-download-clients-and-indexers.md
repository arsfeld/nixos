---
id: task-119
title: Configure MediaManager download clients and indexers
status: Done
assignee: []
created_date: '2025-10-31 18:59'
updated_date: '2025-10-31 19:07'
labels:
  - storage
  - media
  - configuration
  - mediamanager
dependencies: []
priority: medium
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
MediaManager needs to be configured with download clients and indexers to enable automated media acquisition.

**Download Clients to Configure:**
- Transmission (running in VPN namespace on storage)
- qBittorrent (running in VPN namespace on storage)

**Indexers to Configure:**
- Prowlarr (running on storage)
- Jackett (running on storage)

**Documentation:**
- Download Client Configuration: https://maxdorninger.github.io/MediaManager/download-client-configuration.html
- Indexer Settings: https://maxdorninger.github.io/MediaManager/indexer-settings.html

**Investigation Needed:**
1. Find existing download client credentials and connection details for Transmission/qBittorrent
2. Get Prowlarr API key and URL
3. Get Jackett API key and URL
4. Determine correct network paths/URLs for MediaManager container to reach these services
5. Update MediaManager config.toml template with the connection details

**Related:**
- Parent task: task-114 (MediaManager setup)
- MediaManager is running on storage host in container
- Download clients are in VPN namespace (10.200.200.0/24)
- Indexers are in Podman network
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Transmission is configured and accessible in MediaManager
- [x] #2 qBittorrent is configured and accessible in MediaManager
- [x] #3 Prowlarr indexer is configured and accessible in MediaManager
- [x] #4 Jackett indexer is configured and accessible in MediaManager
- [x] #5 MediaManager can successfully test connections to all configured services
- [x] #6 Configuration is persisted in NixOS configuration (config.toml template)
<!-- AC:END -->
