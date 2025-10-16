---
id: task-52
title: Prevent stale cache issues in network-metrics-exporter hostname resolution
status: Done
assignee: []
created_date: '2025-10-16 21:11'
updated_date: '2025-10-16 21:19'
labels:
  - enhancement
  - router
  - networking
  - monitoring
  - bug-prevention
dependencies: []
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
The network-metrics-exporter experienced a stale cache issue (task-50) where the MAC-based cache prevented proper hostname resolution despite correct data in Kea leases. This caused the dashboard to show MAC prefixes instead of hostnames.

## Problem
- Cache entries persisted indefinitely without validation
- When cache lookup succeeded but returned stale data, the exporter didn't fall through to other sources
- No mechanism to detect or recover from cache corruption/staleness
- 2-second DNS timeout delays obscured the real issue

## Proposed Solutions

### 1. Add Cache Expiry/TTL
- Add timestamp to cache entries: `MAC|hostname|timestamp`
- Expire cache entries after 24 hours
- Force re-validation from authoritative sources (Kea) periodically

### 2. Improve Cache Validation
- When reading from cache, verify the entry still matches an authoritative source
- If MAC is in ARP but hostname differs from Kea leases, invalidate cache entry
- Add cache health metrics: `cache_hits`, `cache_misses`, `cache_invalidations`

### 3. Add Fallback on Slow Lookups
- If `getClientName()` takes >500ms, log warning with source being checked
- If cache lookup succeeds but total time >100ms, mark for re-validation
- Track which IPs consistently have slow lookups

### 4. Periodic Cache Cleanup
- Add background task to prune stale/invalid entries every hour
- Remove entries for MACs not seen in ARP table for >7 days
- Log cache cleanup actions for debugging

### 5. Add Monitoring
- Export metric: `hostname_resolution_duration_seconds{ip, source}`
- Alert when resolution takes >1s consistently
- Export metric: `hostname_resolution_source{source}` to track which sources are being used

## Implementation Priority
1. Cache expiry/TTL (prevents indefinite staleness)
2. Monitoring metrics (detects issues early)
3. Cache validation (ensures correctness)
4. Periodic cleanup (maintenance)
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Cache entries have expiry timestamps and are automatically invalidated after 24 hours
- [x] #2 Exporter logs cache invalidations and re-validations
- [x] #3 Prometheus metrics track hostname resolution performance and sources
- [x] #4 Cache cleanup runs periodically and removes stale entries
- [x] #5 Documentation updated to explain cache behavior and troubleshooting
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
## Implementation Summary

### 1. Cache Entry Structure (COMPLETED)
- Added `ClientNameCacheEntry` struct with:
  - `Hostname`: The resolved hostname
  - `Source`: Where the name was resolved from (kea-leases, mdns, dns, etc.)
  - `Timestamp`: When the entry was created/updated
  - `LastSeenIP`: Last IP where this MAC was seen

### 2. Cache Expiry Logic (COMPLETED)
- Cache entries expire after 24 hours (configurable via `cacheExpiryDuration`)
- Expired entries are automatically invalidated when accessed
- Expired entries are skipped during cache save operations
- Expired entries are removed during periodic cleanup

### 3. Prometheus Metrics (COMPLETED)
Added the following metrics:
- `hostname_cache_hits_total`: Cache hit counter
- `hostname_cache_misses_total`: Cache miss counter
- `hostname_cache_invalidations_total{reason}`: Invalidation counter with reasons (expired, updated, cleanup-expired, cleanup-stale)
- `hostname_cache_entries`: Current number of cache entries (gauge)
- `hostname_resolution_duration_seconds{source}`: Histogram of resolution times by source
- `hostname_resolution_source_total{source}`: Counter of resolutions by source

### 4. Periodic Cache Cleanup (COMPLETED)
- Background task runs every hour (starts after 10-minute delay)
- Removes expired entries (>24 hours old)
- Removes stale entries (MACs not in ARP table for >7 days)
- Logs all cleanup actions
- Updates metrics after cleanup
- Saves cleaned cache to disk

### 5. Cache File Format (COMPLETED)
New format: `MAC|Hostname|Source|Timestamp|LastSeenIP`
- Backward compatible with old formats
- Timestamps stored in RFC3339 format
- Sorted by MAC for consistency
- Header comments explain format

### 6. Enhanced Logging (COMPLETED)
- Cache hits log the age and original source
- Cache expirations are logged with age
- Cache updates log the transition (old -> new hostname)
- Cleanup operations are logged in detail
- Timing warnings include the resolution source
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
## Deployment Notes

The changes are backward compatible with existing cache files. The implementation:
- Automatically migrates old cache format (MAC|Name) to new format on load
- Logs all cache operations for easy troubleshooting
- Provides comprehensive Prometheus metrics for monitoring cache health
- Includes detailed documentation in README.md

To deploy:
1. Build and deploy the updated network-metrics-exporter to the router host
2. The service will automatically migrate the existing cache file
3. Monitor the new metrics in Grafana to track cache effectiveness
4. Review logs for any cache-related issues during the first 24 hours
<!-- SECTION:NOTES:END -->
