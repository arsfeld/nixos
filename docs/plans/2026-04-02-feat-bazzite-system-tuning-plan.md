---
title: Bazzite System-Level Tuning (Hardware Drivers & Memory)
type: feat
status: completed
date: 2026-04-02
origin: docs/brainstorms/2026-04-02-bazzite-system-features-brainstorm.md
---

# feat: Bazzite System-Level Tuning (Hardware Drivers & Memory)

## Overview

Extend `modules/constellation/gaming.nix` with Bazzite-style system-level optimizations: per-host CPU frequency driver selection, I/O scheduler udev rules, PSI-based memory pressure monitoring, writeback/compaction tuning, and centralized BORE scheduler sysctl tuning.

## Problem Statement / Motivation

The gaming module already has extensive Bazzite-inspired kernel/sysctl tuning, but has specific gaps (see brainstorm: `docs/brainstorms/2026-04-02-bazzite-system-features-brainstorm.md`):

1. **CPU vendor hardcode bug** — `intel_pstate=active` is hardcoded at `modules/constellation/gaming.nix:37`, but g14 is an AMD Ryzen laptop. The kernel ignores the wrong driver, so g14 gets *no* p-state driver instead of `amd_pstate`.
2. **No I/O scheduler tuning** — Relies on kernel defaults. Bazzite explicitly sets optimal schedulers per device type.
3. **No PSI** — `systemd-oomd` is configured but `psi=1` kernel param is missing, limiting its effectiveness to cgroup-level pressure only.
4. **No writeback/compaction tuning** — `vm.dirty_writeback_centisecs` and `vm.compaction_proactiveness` are unset, leaving potential stutter during gaming.
5. **Scheduler tuning only on raider** — BORE sysctl tweaks in `hosts/raider/scheduler-tuning.nix` benefit all gaming hosts but are not shared.

## Proposed Solution

All changes in `modules/constellation/gaming.nix` (inside the existing `kernelOptimizations` guard), plus host config updates for raider and g14. Delete `hosts/raider/scheduler-tuning.nix`.

## Technical Considerations

### cpuVendor Kernel Param Must Replace, Not Supplement

**Critical:** The hardcoded `"intel_pstate=active"` on line 37 of gaming.nix **must be removed** when adding the conditional cpuVendor logic. If both the old hardcoded line and the new conditional exist, g14 would receive *both* `intel_pstate=active` and `amd_pstate=active`, which is worse than the current bug.

### All New Items Inside `kernelOptimizations` Guard

The existing boot params and sysctls are inside `lib.mkIf config.constellation.gaming.kernelOptimizations { ... }` (line 27). All new kernel params, sysctls, and udev rules must be placed inside this same guard. Someone setting `kernelOptimizations = false` expects a vanilla kernel.

### TLP + amd_pstate Interaction on G14

G14 overrides `services.tlp.enable = true` (gaming.nix defaults it to `false`). TLP's `CPU_SCALING_GOVERNOR_ON_AC = "schedutil"` works correctly with `amd_pstate=active`. The combination is valid — TLP manages the policy, amd_pstate is the driver. This is intentional: g14 is a laptop that needs both gaming performance and battery management.

### Dual OOM Killers (earlyoom + systemd-oomd)

With PSI enabled, both earlyoom (threshold-based, lines 117-129) and systemd-oomd (PSI-based, lines 132-135) will be active. This is the Bazzite pattern — belt-and-suspenders. earlyoom fires first at 5%/2% free memory thresholds; systemd-oomd handles cgroup-level pressure. No conflict expected.

### Scheduler Tuning on G14 (New)

G14 has never had BORE scheduler tuning. The aggressive values (1ms latency) may slightly increase power consumption by causing more frequent scheduling decisions. Using `lib.mkDefault` allows g14 to override if battery life is impacted.

## Acceptance Criteria

- [x] `constellation.gaming.cpuVendor` option exists with enum `["amd" "intel" "none"]`
- [x] Hardcoded `intel_pstate=active` removed from gaming.nix line 37
- [x] Raider config sets `cpuVendor = "intel"`, g14 sets `cpuVendor = "amd"`
- [x] I/O scheduler udev rules in gaming.nix: NVMe→none, SATA SSD→mq-deadline, HDD→bfq
- [x] Udev rules include `SUBSYSTEM=="block"` filter for robustness
- [x] `psi=1` added to kernelParams
- [x] `vm.dirty_writeback_centisecs = 1500` added to sysctl
- [x] `vm.compaction_proactiveness = 0` added to sysctl
- [x] Scheduler tuning (sched_latency_ns, sched_min_granularity_ns, sched_wakeup_granularity_ns) in gaming.nix with `lib.mkDefault`
- [x] `hosts/raider/scheduler-tuning.nix` deleted
- [x] `./scheduler-tuning.nix` removed from raider's imports
- [x] `nix build .#nixosConfigurations.raider.config.system.build.toplevel` succeeds
- [x] `nix build .#nixosConfigurations.g14.config.system.build.toplevel` succeeds

### Post-Deploy Verification

```bash
# Confirm correct p-state driver
cat /proc/cmdline | grep -oE '(amd|intel)_pstate=active'

# Confirm NVMe scheduler (should show [none])
cat /sys/block/nvme0n1/queue/scheduler

# Confirm PSI active (file exists with data)
cat /proc/pressure/memory

# Confirm sysctls
sysctl vm.dirty_writeback_centisecs    # 1500
sysctl vm.compaction_proactiveness     # 0
sysctl kernel.sched_latency_ns         # 1000000
sysctl kernel.sched_min_granularity_ns # 100000
sysctl kernel.sched_wakeup_granularity_ns # 500000
```

## Implementation

All changes in `modules/constellation/gaming.nix` unless noted. All new items go inside the existing `lib.mkIf config.constellation.gaming.kernelOptimizations { ... }` block.

### Phase 1: Add cpuVendor Option + Fix Kernel Params

**`modules/constellation/gaming.nix`** — options block (after line 23):

```nix
cpuVendor = lib.mkOption {
  type = lib.types.enum ["amd" "intel" "none"];
  default = "amd";
  description = "CPU vendor for frequency driver selection (amd_pstate or intel_pstate)";
};
```

**`modules/constellation/gaming.nix`** — kernelParams (lines 30-55):

1. **Remove** `"intel_pstate=active"` from line 37
2. **Add** `"psi=1"` to the static list
3. **Append** conditional p-state param:

```nix
boot.kernelParams = [
  # ... existing static params (without intel_pstate=active) ...
  "psi=1"  # Enable Pressure Stall Information for systemd-oomd
] ++ lib.optional (config.constellation.gaming.cpuVendor == "amd") "amd_pstate=active"
  ++ lib.optional (config.constellation.gaming.cpuVendor == "intel") "intel_pstate=active";
```

### Phase 2: Add I/O Scheduler Udev Rules

**`modules/constellation/gaming.nix`** — inside the `kernelOptimizations` block:

```nix
# I/O scheduler tuning per device type
services.udev.extraRules = ''
  # NVMe: bypass scheduler (hardware handles queuing)
  ACTION=="add|change", SUBSYSTEM=="block", KERNEL=="nvme[0-9]*n[0-9]*", ATTR{queue/scheduler}="none"
  # SATA SSD: mq-deadline (low overhead, good for random I/O)
  ACTION=="add|change", SUBSYSTEM=="block", KERNEL=="sd[a-z]", ATTR{queue/rotational}=="0", ATTR{queue/scheduler}="mq-deadline"
  # HDD: bfq (fair queuing, good for rotational)
  ACTION=="add|change", SUBSYSTEM=="block", KERNEL=="sd[a-z]", ATTR{queue/rotational}=="1", ATTR{queue/scheduler}="bfq"
'';
```

### Phase 3: Add Memory Tuning Sysctls

**`modules/constellation/gaming.nix`** — add to existing `boot.kernel.sysctl` block (after line 68):

```nix
# Writeback throttling (reduces I/O stutter during gaming)
"vm.dirty_writeback_centisecs" = 1500;  # 15s periodic writeback

# Disable proactive THP compaction (reduces latency spikes)
"vm.compaction_proactiveness" = 0;
```

### Phase 4: Merge Scheduler Tuning

**`modules/constellation/gaming.nix`** — add to existing `boot.kernel.sysctl` block (after gaming performance section, ~line 72):

```nix
# BORE scheduler tuning for desktop interactivity
"kernel.sched_latency_ns" = lib.mkDefault 1000000;          # 1ms
"kernel.sched_min_granularity_ns" = lib.mkDefault 100000;    # 0.1ms
"kernel.sched_wakeup_granularity_ns" = lib.mkDefault 500000; # 0.5ms
```

### Phase 5: Host Config Updates

**`hosts/raider/configuration.nix`:**
1. Remove `./scheduler-tuning.nix` from imports (line 15)
2. Add `constellation.gaming.cpuVendor = "intel";` to the constellation block

**`hosts/g14/configuration.nix`:**
1. Add `constellation.gaming.cpuVendor = "amd";` to the constellation block

**`hosts/raider/scheduler-tuning.nix`:**
1. Delete the file

### Phase 6: Build Verification

```bash
nix build .#nixosConfigurations.raider.config.system.build.toplevel
nix build .#nixosConfigurations.g14.config.system.build.toplevel
```

## Dependencies & Risks

| Risk | Likelihood | Mitigation |
|------|-----------|------------|
| Forgetting to remove hardcoded `intel_pstate=active` | Low (explicit in plan) | Phase 1 step 1 is specifically this removal |
| BORE scheduler tuning increases g14 battery drain | Low-Medium | Values use `lib.mkDefault`, g14 can override |
| bfq/mq-deadline not in XanMod kernel | Very Low | XanMod ships all schedulers; kernel ignores unknown scheduler in udev |
| earlyoom and systemd-oomd race on same process | Very Low | Different trigger mechanisms; earlyoom fires first at threshold |

## Sources & References

- **Origin brainstorm:** [docs/brainstorms/2026-04-02-bazzite-system-features-brainstorm.md](docs/brainstorms/2026-04-02-bazzite-system-features-brainstorm.md) — Key decisions: cpuVendor per-host option, udev rules for I/O scheduler, full PSI+writeback+compaction stack, merge scheduler tuning, approach A+C
- **Primary file:** `modules/constellation/gaming.nix` (line 37: hardcoded `intel_pstate=active` to remove; lines 27-107: `kernelOptimizations` block to modify)
- **Scheduler tuning source:** `hosts/raider/scheduler-tuning.nix` (to merge and delete)
- **Host configs:** `hosts/raider/configuration.nix` (line 15: scheduler import to remove), `hosts/g14/configuration.nix` (add cpuVendor)
- **Udev pattern:** `hosts/octopi/hardware-configuration.nix:78` (existing `services.udev.extraRules` example)
- **Bazzite reference:** [github.com/ublue-os/bazzite](https://github.com/ublue-os/bazzite) — kernel params, sysctl tuning, I/O scheduler rules
