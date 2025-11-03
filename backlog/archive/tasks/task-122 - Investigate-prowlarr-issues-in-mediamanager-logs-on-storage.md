---
id: task-122
title: Investigate prowlarr issues in mediamanager logs on storage
status: Done
assignee: []
created_date: '2025-10-31 19:52'
updated_date: '2025-10-31 19:56'
labels:
  - storage
  - mediamanager
  - prowlarr
  - debugging
dependencies: []
priority: medium
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Check the mediamanager container logs on the storage host to identify and resolve any prowlarr-related issues that may be affecting indexer functionality.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Prowlarr logs have been reviewed and any errors identified
- [x] #2 Root cause of prowlarr issues has been determined
- [x] #3 Fix has been implemented or documented for follow-up
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
## Investigation Summary

**Prowlarr Version:** 2.1.5.5216-ls131 (linuxserver image)
**Error Found:** `System.NotSupportedException: Memory stream is not expandable`

## Root Cause

The error occurs when Prowlarr encounters **corrupted or malformed torrent files** from indexers (observed with 1337x and EZTV). When the MonoTorrent library tries to decode the BEncoded torrent data, it fails if the file structure is invalid or exceeds expected buffer sizes.

## Analysis

This is **not a configuration issue** with Prowlarr:

1. **Expected Behavior**: The error is normal when processing bad torrent files from indexers
2. **Already Fixed**: GitHub issue #2169 fixed the noisy logging (commit 7bada44, Oct 13, 2024)
3. **External Bug**: Tagged as external bug - the problem originates from third-party indexer data
4. **Upstream Issue**: Prowlarr correctly rejects invalid torrents; the indexers are serving corrupted files

## Impact Assessment

- **Severity**: Low - Only affects specific torrents that are already corrupted
- **Functionality**: Other torrents from same indexers work fine
- **Errors are Non-Critical**: Downloads continue to work for valid torrents

## Recommendations

**No immediate action required** because:

1. Current version (2.1.5.5216) is recent and includes the logging fix
2. Errors are expected behavior for corrupted torrent files
3. This doesn't impact overall indexer functionality
4. The vast majority of searches succeed (only specific torrents fail)

**Optional Actions** (if errors become excessive):

- Monitor if specific indexers consistently return bad torrents
- Consider disabling problematic indexers if error rate is high
- Check indexer health status in Prowlarr UI
- Update to latest version if a newer release addresses torrent validation

## Conclusion

✅ Prowlarr is working correctly
✅ Errors are from external sources (bad torrent files)
✅ No configuration changes needed
✅ System continues to function normally
<!-- SECTION:NOTES:END -->
