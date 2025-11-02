---
id: task-132
title: Investigate and fix MediaManager crash
status: Done
assignee: []
created_date: '2025-11-02 12:02'
updated_date: '2025-11-02 13:34'
labels:
  - bug
  - mediamanager
  - storage
dependencies: []
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
MediaManager is crashing and needs investigation to determine the root cause and implement a fix.

**Current Status:**
- MediaManager service is crashing
- Impact on service availability unknown

**Investigation needed:**
- Review systemd service logs for crash details
- Check application logs for error messages
- Identify crash trigger (startup, runtime, specific operations)
- Determine if related to recent configuration changes (OAuth, database, path mappings)

**Related completed tasks:**
- task-118: Fixed OAuth callback 500 error
- task-114: Fixed database connection
- task-121: Deployed path configuration fixes
- task-119: Configured download clients and indexers
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Root cause of crash identified through log analysis
- [x] #2 Fix implemented and deployed
- [x] #3 MediaManager service running stably without crashes
- [x] #4 Service logs confirm successful startup and operation
- [x] #5 No regression in existing functionality (OAuth, database, download clients)
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
## Investigation Results

**Root Cause Identified:**
MediaManager service didn't crash catastrophically - it was gracefully shut down at 03:55:47 EST and restarted at 04:02:31 EST (likely due to deployment). However, there's a critical configuration error causing Transmission connection failures.

**The Bug:**
At `modules/constellation/media.nix:148`, the Transmission host is configured as:
```toml
host = "http://192.168.15.1"
```

MediaManager's URL parser treats the `host` field as a hostname only (not a full URL), so it expects just `192.168.15.1`. When it encounters `http://192.168.15.1`, the parser gets confused and treats "http" as the hostname, attempting to connect via HTTPS (port 443) with path `/192.168.15.1:9091/transmission/rpc`.

**Error Evidence:**
```
HTTPSConnectionPool(host='http', port=443): Max retries exceeded with url: /192.168.15.1:9091/transmission/rpc (Caused by NameResolutionError: Failed to resolve 'http')
```

**Solution:**
Remove the protocol prefix from the host field. Change `host = "http://192.168.15.1"` to `host = "192.168.15.1"`

## Resolution

**Fix Deployed:**
Fixed Transmission configuration in `modules/constellation/media.nix:146-150`

**Changes Made:**
1. Removed `http://` protocol prefix from Transmission host field
2. Added `https_enabled = false` to explicitly use HTTP instead of HTTPS

**Verification:**
Service logs at 08:30:00 EST confirm successful Transmission connectivity:
```
Successfully connected to Transmission
Transmission client initialized and set as active torrent client
Download manager initialized with active download clients: torrent (transmission)
```

Both scheduled jobs (import_all_movie_torrents and import_all_show_torrents) are executing successfully every 15 minutes with no errors.
<!-- SECTION:NOTES:END -->
