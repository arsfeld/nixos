---
id: task-102
title: Investigate LVM2 RAID1 with lvmcache as alternative to btrfs
status: Done
assignee: []
created_date: '2025-10-29 15:08'
updated_date: '2025-10-29 15:13'
labels:
  - storage
  - filesystem
  - lvm
  - lvmcache
  - raid1
  - investigation
  - performance
dependencies:
  - task-101
priority: medium
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Research and evaluate LVM2 with RAID1 and lvmcache (SSD caching) as an alternative to the planned btrfs RAID1 migration.

**Context:**
- Task #101 planned btrfs RAID1 migration but excluded SSDs due to lack of native tiered storage
- Current setup: bcachefs with 4 HDDs + 2 SSDs in tiered configuration
- The 2x512GB Samsung SSDs are currently unused in the btrfs plan
- LVM2 has native caching support via lvmcache (uses dm-cache underneath)

**Goal:**
Determine if LVM2 RAID1 + lvmcache + filesystem (ext4/xfs) is a better alternative than btrfs RAID1 alone, considering performance, reliability, and maintainability.

**Research Areas:**
1. LVM RAID1 stability and performance vs btrfs RAID1
2. lvmcache implementation (writeback vs writethrough modes)
3. Filesystem choice on top of LVM (ext4 vs xfs vs others)
4. Feature comparison vs btrfs (compression, snapshots, checksumming)
5. NixOS/disko support for LVM + lvmcache configuration
6. Operational complexity (administration, monitoring, recovery)
7. Backup and snapshot strategies with LVM

**Key Questions:**
- How does LVM RAID1 reliability compare to btrfs RAID1?
- Can lvmcache effectively utilize 2x512GB SSDs for the HDD array?
- What cache mode is safest (writethrough vs writeback)?
- Do we lose important btrfs features (compression, snapshots, checksums)?
- Can LVM snapshots replace btrfs subvolume snapshots?
- Is LVM + lvmcache more or less complex than btrfs?
- How does this perform compared to bcachefs tiered storage?
- What happens when cache SSD fails?

**Trade-offs to Consider:**
- **LVM Pros**: Native SSD caching, mature/stable, good tooling
- **LVM Cons**: Less integrated than btrfs, no CoW, need to choose separate filesystem
- **Btrfs Pros**: Modern features (CoW, compression, checksums), snapshots, all-in-one
- **Btrfs Cons**: No native SSD caching, more complex RAID5/6 issues

**Success Criteria:**
- Clear comparison: LVM2+lvmcache vs btrfs RAID1
- Documented pros/cons for this specific use case
- Performance and reliability assessment
- If viable: Draft LVM+lvmcache configuration for disko
- Decision recommendation with clear reasoning
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Research LVM RAID1 stability and performance characteristics
- [x] #2 Investigate lvmcache configuration and cache modes
- [x] #3 Compare filesystem options (ext4, xfs) on top of LVM
- [x] #4 Document feature parity analysis vs btrfs (compression, snapshots, checksums)
- [x] #5 Evaluate NixOS/disko support for LVM + lvmcache
- [x] #6 Assess operational complexity and maintenance burden
- [x] #7 Create draft configuration if viable, or explain why btrfs is better
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
## Research Findings

### 1. LVM RAID1 Stability & Performance

**Status:** Mature and production-ready for RAID1
- Modern LVM RAID uses MD (Multiple Devices) kernel drivers
- RAID1 is stable and well-tested (unlike RAID5/6 which are less reliable)
- Performance comparable to mdadm RAID1
- Many admins still prefer mdadm + LVM-on-top for separation of concerns
- Not cluster-aware (cannot activate on multiple machines simultaneously)

**Recommendation:** LVM RAID1 is reliable for single-host NAS scenarios

---

### 2. lvmcache (dm-cache) Configuration

**Cache Modes:**

**Writethrough (default):**
- ✅ Safe: Data written to both cache AND origin
- ✅ Cache loss = no data loss
- ❌ Slower performance

**Writeback:**
- ✅ Higher performance (delays writes to origin)
- ❌ Dangerous: Cache loss = DATA LOSS
- ⚠️ After system crash, ALL blocks considered dirty
- ⚠️ Requires redundant cache devices for safety

**Critical Finding:** For writeback mode with RAID, you need ONE SSD PER HDD in the mirror. Sharing one SSD across multiple mirror legs defeats redundancy.

---

### 3. Filesystem Comparison: ext4 vs XFS

**ext4:**
- Better for small files and single-threaded workloads
- Can shrink filesystems (flexible)
- More metadata-intensive
- Good all-around choice

**XFS:**
- Better for large files (hundreds of MB+)
- Better for parallel/multi-threaded I/O
- Cannot shrink (only grow)
- Optimal for large storage arrays
- More efficient metadata on sync random writes

**Recommendation:** For /mnt/storage with large media files, XFS is superior

---

### 4. Feature Parity: Btrfs vs LVM+ext4/xfs

**Btrfs Features:**
- ✅ Checksums on ALL data and metadata (crc32c, xxhash64, sha256, blake2)
- ✅ Self-healing with RAID (can identify which copy is corrupted)
- ✅ Transparent compression (zstd, zlib, lzo)
- ✅ CoW (Copy-on-Write)
- ✅ Efficient snapshots (instant, no space overhead until divergence)
- ✅ Subvolumes
- ❌ No native SSD caching/tiering

**LVM + ext4/xfs:**
- ✅ Native SSD caching via lvmcache
- ✅ LVM snapshots (but slower, space overhead)
- ✅ Mature, proven stability
- ❌ No checksums (corruption goes undetected)
- ❌ No compression
- ❌ No CoW
- ❌ No self-healing

**Critical Trade-off:** Checksums vs SSD caching

---

### 5. Hybrid Solution: Btrfs on LVM Cache

**MAJOR DISCOVERY:** You CAN layer btrfs on top of LVM cache!

Source: https://www.dont-panic.cc/capi/2022/11/22/speeding-up-btrfs-raid1-with-lvm-cache/

**Architecture:**
```
[Btrfs RAID1 Filesystem]
        |
   [LVM Volumes]
        |
   [LVM Cache Layer (writeback)]
        |
  [Physical Disks]
```

**Advantages:**
- ✅ Get btrfs features (checksums, compression, snapshots, CoW)
- ✅ Get SSD acceleration via lvmcache
- ✅ Btrfs RAID1 redundancy protects against single device failures

**Critical Caveats:**
- ⚠️ SSD failure in writeback mode WILL CORRUPT the cached HDD data
- ⚠️ BUT: Btrfs RAID1 provides redundancy, so other mirror leg remains intact
- ⚠️ Requires ONE SSD per HDD for proper RAID protection
- ⚠️ After SSD failure, must detach cache and run `btrfs scrub` to repair
- ⚠️ NOT suitable for high-availability (requires admin intervention)

**Design Philosophy:** Prioritizes "reducing the number of times I have to reach for backups, not to increase uptime"

---

### 6. NixOS/disko Support

**Finding:** Disko does NOT have native lvmcache support

Sources:
- GitHub issue #814 (October 2024): User asking how to configure LVM cache with disko
- No examples in disko repository for lvmcache
- disko/example/lvm-raid.nix exists but doesn't show cache setup

**Workaround Required:**
1. Use disko to create basic LVM RAID1 volumes
2. Manually configure cache pools via systemd services
3. Add kernel modules to NixOS config:
   - boot.initrd.kernelModules = ["dm-cache" "dm-cache-smq" "dm-cache-mq" "dm-cache-cleaner"]
   - services.lvm.boot.thin.enable = true (for caching/thin provisioning)

**Complexity:** Medium-High (requires post-disko setup scripts)

---

### 7. Operational Complexity Assessment

**Btrfs RAID1 Only (Task #101 plan):**
- ✅ Simple: Single filesystem layer
- ✅ Native disko support
- ✅ Standard btrfs tools (btrfs scrub, balance, etc.)
- ✅ Well-documented in NixOS community
- ❌ SSDs left unused
- **Complexity: Low**

**LVM RAID1 + lvmcache + XFS:**
- ❌ Multiple layers to manage (LVM RAID, cache, filesystem)
- ❌ No disko support for cache (manual setup)
- ❌ Custom systemd services for cache attachment
- ❌ More failure modes (cache, RAID, filesystem)
- ❌ No checksums, no compression
- ✅ SSDs utilized
- **Complexity: High**

**Btrfs RAID1 on LVM Cache (Hybrid):**
- ❌ Multiple layers: LVM cache + btrfs RAID1
- ❌ No disko support (manual setup)
- ❌ Custom systemd services required
- ❌ Complex failure recovery (detach cache, scrub btrfs)
- ❌ Risk: SSD failure corrupts cached data (requires btrfs repair)
- ✅ SSDs utilized
- ✅ Get all btrfs features
- ✅ Btrfs redundancy mitigates cache corruption
- **Complexity: Very High**

---

### 8. Performance Comparison

From research:
- **bcache:** Best performance (~48k IOPS, impressive acceleration)
- **lvmcache:** Modest performance boost, but predictable
- **bcachefs:** Best integration (filesystem + tiering native), but unstable on this system

**Reality Check:** The storage host bcachefs is in read-only mode due to corruption issues. Stability > Performance.

---

## FINAL RECOMMENDATION

### The Problem with This Hardware Configuration

**Critical Constraint:** Storage host has:
- 4x HDDs (2x 14TB Seagate + 2x 8TB WD)
- 2x 512GB Samsung SSDs

**LVM Cache Safety Rule:** ONE SSD PER HDD for RAID redundancy

**Math doesn't work:** 4 HDDs need 4 SSDs, but we only have 2 SSDs.

**Unsafe alternatives:**
1. Share 1 SSD across 2 HDDs in the same mirror leg → SSD failure loses ENTIRE mirror leg
2. Use one SSD for both mirror legs → Defeats RAID redundancy entirely

---

### Option Analysis

#### Option 1: Btrfs RAID1 Only (Task #101 Plan) ⭐ RECOMMENDED

**Pros:**
- ✅ Simple, single filesystem layer
- ✅ Native disko support (easy deployment)
- ✅ All btrfs features: checksums, compression, snapshots, CoW, self-healing
- ✅ Low operational complexity
- ✅ Well-tested in NixOS community
- ✅ No risky cache failure scenarios
- ✅ 20TB usable capacity (40TB raw)

**Cons:**
- ❌ SSDs unused (but see Alternative Use Cases below)
- ❌ No SSD acceleration for /mnt/storage

**Risk Level:** Low  
**Complexity:** Low  
**Stability:** High

---

#### Option 2: Btrfs RAID1 on LVM Cache (Hybrid) ⚠️ NOT RECOMMENDED

**Pros:**
- ✅ All btrfs features
- ✅ SSD acceleration
- ✅ Btrfs redundancy mitigates cache corruption

**Cons:**
- ❌ UNSAFE: Only 2 SSDs for 4 HDDs (violates safety rule)
- ❌ Very high complexity (multiple layers)
- ❌ No disko support (manual setup)
- ❌ Complex failure recovery
- ❌ SSD failure corrupts cached data, requires btrfs scrub
- ❌ Requires custom systemd services
- ❌ Risk of admin error during recovery

**Risk Level:** High  
**Complexity:** Very High  
**Stability:** Medium

**Verdict:** Complexity and risk not justified for a home NAS where backups exist

---

#### Option 3: LVM RAID1 + lvmcache + XFS ❌ NOT RECOMMENDED

**Pros:**
- ✅ SSD acceleration
- ✅ XFS good for large files

**Cons:**
- ❌ UNSAFE: Same SSD/HDD ratio problem
- ❌ No checksums (corruption goes undetected)
- ❌ No compression
- ❌ No CoW
- ❌ No self-healing
- ❌ High complexity
- ❌ No disko support

**Verdict:** Loses too many btrfs features, still unsafe

---

### Alternative Use Cases for the 2x512GB SSDs

Instead of using SSDs for /mnt/storage cache:

1. **VM Storage:** Fast storage for Incus/LXC containers on storage host
2. **Container Volumes:** High-IOPS storage for databases (PostgreSQL, Redis)
3. **Build Cache:** Fast storage for Nix builds and Attic cache metadata
4. **Log Storage:** Fast write storage for observability hub (Prometheus, Loki)
5. **Scratch Space:** Temporary processing for media transcoding
6. **RAID1 Pair:** Create separate 512GB btrfs RAID1 for high-performance workloads

**Best Option:** Create separate btrfs RAID1 with the 2 SSDs for container/VM workloads, leaving /mnt/storage as HDD-only btrfs RAID1.

---

### Decision Matrix

| Criterion | Btrfs Only | Btrfs+LVM Cache | LVM+XFS+Cache |
|-----------|------------|-----------------|---------------|
| Checksums | ✅ Yes | ✅ Yes | ❌ No |
| Compression | ✅ Yes | ✅ Yes | ❌ No |
| Self-Healing | ✅ Yes | ✅ Yes | ❌ No |
| Snapshots | ✅ Efficient | ✅ Efficient | ⚠️ LVM (slow) |
| SSD Cache | ❌ No | ✅ Yes | ✅ Yes |
| Safety | ✅ Safe | ⚠️ Risky | ⚠️ Risky |
| Complexity | ✅ Low | ❌ Very High | ❌ High |
| Disko Support | ✅ Yes | ❌ No | ❌ No |
| Maintenance | ✅ Simple | ❌ Complex | ❌ Complex |

---

### Final Verdict

**RECOMMENDATION: Proceed with Task #101's btrfs RAID1-only plan**

**Reasoning:**
1. **Safety First:** Current bcachefs corruption shows stability is critical
2. **Hardware Mismatch:** 2 SSDs insufficient for safe caching of 4 HDDs
3. **Feature Priority:** Checksums and self-healing more valuable than SSD speed for archival NAS
4. **Simplicity:** Easier to maintain and recover
5. **Proven Path:** Well-tested in NixOS/disko community
6. **SSD Alternative:** Use SSDs for dedicated high-IOPS workloads instead

**Performance Reality:**
- Btrfs compression (zstd) reduces I/O, partially compensating for no SSD cache
- Media streaming doesn't need SSD speeds (sequential reads from HDDs are fine)
- Random I/O workloads should use separate SSD pool anyway

**The trade-off of SSD caching complexity and risk is NOT worth it for this use case.**

---
<!-- SECTION:NOTES:END -->
