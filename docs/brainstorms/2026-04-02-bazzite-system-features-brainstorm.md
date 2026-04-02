# Brainstorm: Bazzite System-Level Features (Hardware Drivers & Memory Tuning)

**Date:** 2026-04-02
**Status:** Draft
**Scope:** `modules/constellation/gaming.nix` + host configs

## What We're Building

Extend gaming.nix with Bazzite-style system-level optimizations that were skipped in the first Bazzite alignment pass (which focused on GNOME UX). This covers:

1. **CPU frequency driver selection** — Per-host `cpuVendor` option to set `amd_pstate=active` or `intel_pstate=active`
2. **I/O scheduler tuning** — Udev rules for optimal scheduler per device type (NVMe, SATA SSD, HDD)
3. **Memory pressure monitoring** — PSI (`psi=1`), writeback throttling, THP compaction tuning
4. **Scheduler tuning** — Merge raider's BORE sysctl tweaks into the shared module
5. **G14 fix** — Remove incorrect `intel_pstate=active` from gaming module default (it's an AMD laptop)

## Why This Approach

The first Bazzite alignment (2026-04-01) focused on GNOME desktop UX. The gaming.nix module already has extensive Bazzite-inspired kernel/sysctl tuning, but has gaps in:
- CPU vendor awareness (hardcoded Intel)
- I/O scheduler (relies on kernel defaults)
- Memory pressure visibility (PSI not enabled)
- Dirty writeback tuning (stutter source in gaming)
- Scheduler tuning only on raider, not shared

Centralizing everything in gaming.nix follows the existing pattern and ensures all gaming hosts (raider, g14, future) get the same baseline.

## Key Decisions

### 1. CPU Vendor Option

Add `constellation.gaming.cpuVendor` option:
- Type: `enum ["amd" "intel" "none"]`, default `"amd"`
- `"amd"` → adds `amd_pstate=active` to kernelParams
- `"intel"` → adds `intel_pstate=active` to kernelParams
- `"none"` → no p-state param (let kernel auto-detect)

Remove the hardcoded `intel_pstate=active` from gaming.nix kernelParams.

Host configs set:
- `raider`: `cpuVendor = "intel"` (12th gen Intel)
- `g14`: `cpuVendor = "amd"` (Ryzen)

### 2. I/O Scheduler Udev Rules

Add `services.udev.extraRules` in gaming.nix:

```
# NVMe: 'none' is optimal (bypass scheduler, hardware handles queuing)
ACTION=="add|change", KERNEL=="nvme[0-9]*", ATTR{queue/scheduler}="none"

# SATA SSD: mq-deadline (low overhead, good for random I/O)
ACTION=="add|change", KERNEL=="sd[a-z]", ATTR{queue/rotational}=="0", ATTR{queue/scheduler}="mq-deadline"

# HDD: bfq (fair queuing, good for rotational)
ACTION=="add|change", KERNEL=="sd[a-z]", ATTR{queue/rotational}=="1", ATTR{queue/scheduler}="bfq"
```

### 3. PSI + Writeback + Compaction

**Kernel param:**
```nix
"psi=1"  # Enable Pressure Stall Information
```

**Sysctl additions:**
```nix
"vm.dirty_writeback_centisecs" = 1500;  # 15s writeback interval (Bazzite default, reduces stutter)
"vm.compaction_proactiveness" = 0;       # Disable proactive THP compaction (reduces latency spikes)
```

PSI enables systemd-oomd (already configured) to make smarter OOM decisions based on actual memory pressure rather than just free memory thresholds.

### 4. Scheduler Tuning (Merge from raider)

Move these from `hosts/raider/scheduler-tuning.nix` into `gaming.nix` kernel.sysctl:

```nix
"kernel.sched_latency_ns" = 1000000;          # 1ms (better responsiveness)
"kernel.sched_min_granularity_ns" = 100000;    # 0.1ms
"kernel.sched_wakeup_granularity_ns" = 500000; # 0.5ms
```

Use `lib.mkDefault` so hosts can override for battery-sensitive scenarios.

Delete `hosts/raider/scheduler-tuning.nix` and remove its import from raider's configuration.nix.

### 5. G14 Fix

G14's kernelParams already duplicate several gaming.nix params (`zswap.enabled=0`, `mitigations=off`, `nmi_watchdog=0`). These should be left as-is for now (NixOS merges kernel params lists, duplicates are harmless). The real fix is making cpuVendor configurable so g14 gets `amd_pstate=active` instead of `intel_pstate=active`.

## What We're NOT Doing

- **USB autosuspend exclusions** — No input lag issues observed, skip
- **Automated system updates** — Different scope, not hardware-related
- **UKI/Secure Boot** — Too invasive, not a tuning change
- **Real-time kernel** — XanMod with BORE is sufficient
- **Refactoring gaming.nix into named groups** — YAGNI, the file is readable as-is

## Resolved Questions

1. **Where should optimizations live?** → All in gaming.nix (centralized)
2. **CPU vendor detection?** → Per-host option (`cpuVendor`), not auto-detect
3. **I/O scheduler method?** → Udev rules (per-device-type, standard approach)
4. **USB autosuspend?** → Skip (no issues observed)
5. **Memory tuning scope?** → Full: PSI + writeback + compaction
6. **Scheduler tuning?** → Merge raider's into gaming.nix, delete host file
7. **Approach?** → A + C fix (minimal changes + fix g14 intel_pstate bug)
