---
id: task-102
title: Investigate using dm-cache with btrfs for SSD caching
status: To Do
assignee: []
created_date: '2025-10-29 14:40'
labels:
  - storage
  - filesystem
  - btrfs
  - cache
  - dm-cache
  - investigation
  - performance
dependencies:
  - task-101
priority: medium
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Research and evaluate dm-cache (device mapper cache) as a solution for adding SSD caching to the btrfs RAID1 storage array.

**Context:**
- Task #101 planned btrfs RAID1 migration but excluded SSDs (2x512GB Samsung)
- Reason for exclusion: Btrfs lacks native tiered storage/SSD caching like bcachefs
- The 2 SSDs are currently unused and could provide significant performance improvement
- dm-cache operates at the block device layer (below the filesystem)

**Goal:**
Determine if dm-cache is a viable solution for adding SSD caching to the btrfs array without sacrificing reliability or adding excessive complexity.

**Research Areas:**
1. dm-cache compatibility with btrfs RAID1 (any known issues?)
2. Performance characteristics (cache hit rates, latency improvements)
3. Reliability implications (does it add new failure modes?)
4. Configuration complexity in NixOS (how hard to set up and maintain?)
5. Alternative approaches (lvmcache, bcache, etc.) comparison
6. Impact on existing backup/snapshot workflows

**Key Questions:**
- Can dm-cache work with btrfs multi-device RAID1?
- Should cache be applied per-device or to the entire array?
- What are the cache policies (writethrough vs writeback)?
- How does this interact with btrfs's CoW and checksumming?
- What happens if an SSD fails?
- Is there NixOS/disko support for dm-cache?

**Success Criteria:**
- Clear understanding of dm-cache feasibility with btrfs
- Documented pros/cons vs alternatives
- If viable: Draft configuration or implementation plan
- If not viable: Documented reasons and alternative recommendations
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Research dm-cache compatibility with btrfs multi-device RAID1
- [ ] #2 Compare dm-cache vs bcache vs lvmcache for this use case
- [ ] #3 Document performance implications and cache policies
- [ ] #4 Assess reliability and failure scenarios
- [ ] #5 Evaluate NixOS/disko configuration complexity
- [ ] #6 Create implementation plan if viable, or document why not
- [ ] #7 Consider impact on backup/snapshot workflows
<!-- AC:END -->
