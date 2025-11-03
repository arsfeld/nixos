---
id: task-125
title: Fix Radarr remote path mapping for Transmission downloads
status: In Progress
assignee: []
created_date: '2025-11-02 00:22'
updated_date: '2025-11-02 00:34'
labels:
  - bug
  - radarr
  - transmission
  - media
  - storage
dependencies: []
priority: medium
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Radarr is configured to use Transmission as a remote download client, but there's a path mapping issue:

**Problem:**
- Transmission places downloads in `/mnt/storage/media/downloads/radarr`
- This directory does not appear to exist on the system
- Likely caused by missing or incorrect remote path mapping configuration

**Investigation needed:**
1. Verify the actual download path Transmission is using
2. Check if the directory structure exists on storage host
3. Review Radarr's remote path mapping configuration
4. Determine if this is a configuration issue or missing directory

**Context:**
- Related to MediaManager (Radarr) setup on storage host
- Transmission may be running in a container or as native service (task-108 is migrating to native)
- Path mappings need to align between Radarr and Transmission configurations
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Directory `/mnt/storage/media/downloads/radarr` exists on storage host OR remote path mapping is correctly configured to map Transmission's actual path
- [ ] #2 Radarr can successfully detect and import downloads from Transmission
- [ ] #3 Test download completes successfully and Radarr moves it to the media library
- [ ] #4 No path-related errors in Radarr logs when interacting with Transmission
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
## Investigation Plan

1. Check actual directory structure on storage host at `/mnt/storage/media/`
   - Likely has `Downloads` (capital D) instead of `downloads` (lowercase)
   
2. Review and fix Transmission configuration in `hosts/storage/services/transmission-vpn.nix`
   - Update paths to match actual directory structure
   
3. Review MediaManager config template in `modules/constellation/media.nix`
   - Ensure torrent_directory matches Transmission paths
   
4. Deploy fixes to storage host

5. Verify Radarr can now properly detect and import downloads from Transmission

## Key Files
- `hosts/storage/services/transmission-vpn.nix` - Transmission paths
- `modules/constellation/media.nix` - MediaManager config template
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
## Investigation Findings

**Root Cause**: Directory name case mismatch
- Transmission configuration used lowercase `downloads`
- Storage host had lowercase `/mnt/storage/media/downloads`
- Should have been capital `Downloads`

**Changes Made**:
1. Renamed `/mnt/storage/media/downloads` → `/mnt/storage/media/Downloads` on storage host
2. Created `/mnt/storage/media/Downloads/radarr` directory with proper permissions (media:media, 775)
3. Updated `hosts/storage/services/transmission-vpn.nix:36` - changed `download-dir` from `downloads` to `Downloads`
4. Updated `hosts/storage/services/transmission-vpn.nix:84-86` - added preStart directory creation for `Downloads`, `Downloads/radarr`, and `Downloads/sonarr`
5. Updated `modules/constellation/media.nix:91` - changed MediaManager `torrent_directory` from `downloads` to `Downloads`

**Files Modified**:
- `hosts/storage/services/transmission-vpn.nix`
- `modules/constellation/media.nix`
<!-- SECTION:NOTES:END -->
