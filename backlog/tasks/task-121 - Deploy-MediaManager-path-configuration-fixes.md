---
id: task-121
title: Deploy MediaManager path configuration fixes
status: Done
assignee: []
created_date: '2025-10-31 19:25'
updated_date: '2025-10-31 19:26'
labels:
  - mediamanager
  - storage
  - configuration
dependencies: []
priority: medium
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Fixed MediaManager configuration to use correct folder paths matching the actual storage structure:
- TV directory: /mnt/storage/media/Series (was /media/tv)
- Movie directory: /mnt/storage/media/Movies (was /media/movies)  
- Download directory: /mnt/storage/media/downloads (already correct)

Also cleaned up duplicate empty folders (Downloads, tv, movies).

Changes need to be deployed to storage host to update the MediaManager config.toml template.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 MediaManager config.toml template updated on storage host
- [x] #2 MediaManager container restarted with new configuration
- [x] #3 Paths correctly point to Series, Movies, and downloads folders
<!-- AC:END -->
