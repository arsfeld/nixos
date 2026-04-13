---
title: Pull Bazzite streaming, Wine perf, and scx scheduler into constellation.gaming
type: feat
status: active
date: 2026-04-12
origin: docs/brainstorms/2026-04-12-bazzite-streaming-wine-scheduler-brainstorm.md
---

# feat(gaming): Bazzite streaming, Wine perf & scx scheduler

## Overview

Add three Bazzite-sourced features to `modules/constellation/gaming.nix`, all consumed by raider today:

1. **Sunshine** game streaming service, Tailscale-scoped firewall only
2. **Wine/Proton performance** — ntsync kernel module + UMU Launcher + DXVK/Mesa shader cache relocation
3. **scx_sched_ext** BPF schedulers, replacing the disabled `system76-scheduler` line

All behind new nested sub-options on `constellation.gaming`, default-enabled, so raider inherits automatically and g14 (the other gaming-module host) can opt out per-feature if needed.

Originates from brainstorm [`2026-04-12-bazzite-streaming-wine-scheduler-brainstorm.md`](../brainstorms/2026-04-12-bazzite-streaming-wine-scheduler-brainstorm.md).

## Problem Statement / Motivation

The `constellation.gaming` module is explicitly "inspired by Bazzite" (module docstring at `modules/constellation/gaming.nix:1-2`). Two prior alignment passes landed — GNOME UX (brainstorm `2026-04-01`) and kernel/IO/memory tuning (brainstorm `2026-04-02`, now implemented). Three Bazzite-defining features remain un-pulled:

- **No game streaming host.** Bazzite ships Sunshine as a headline feature for Moonlight clients. We have nothing equivalent — raider can't stream games to phone/TV/laptop.
- **Wine/Proton tuning lags upstream.** ntsync has been in the Linux kernel since 6.14 (xanmod ships it), Proton 9+ auto-uses it, but we don't load the module or set the uaccess udev rule. UMU Launcher is now the upstream entry point Lutris/Heroic/Bottles use, and bundling it explicitly reduces Proton/runtime duplication. DXVK/Mesa shader caches live in `~/.cache` with small defaults; AAA titles cause thrash.
- **Dead scheduler line.** `services.system76-scheduler.enable = false;` sits at `modules/constellation/gaming.nix:361` with a comment that it "causes high context switches and freezing." Nothing replaces it, so we fall back to stock CFS. Bazzite (via CachyOS) stabilized on `scx_lavd` — a BPF-based scheduler that's much more robust than the sys76 userspace daemon and auto-unloads to CFS on failure.

## Proposed Solution

All changes land in `modules/constellation/gaming.nix`. No host-level changes required for raider (sub-options are default-on).

### New option surface

```nix
options.constellation.gaming = {
  # ... existing options (enable, kernelOptimizations, gamingMode, cpuVendor, performanceOsd) ...

  streaming = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable Sunshine game streaming host (Tailscale-only exposure)";
    };
  };

  wineTuning = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable Wine/Proton perf tuning: ntsync, UMU launcher, shader cache relocation";
    };
  };

  scheduler = lib.mkOption {
    type = lib.types.enum ["none" "lavd" "bpfland" "rusty"];
    default = "lavd";
    description = ''
      sched_ext BPF scheduler to run.
      - lavd: Latency-Aware Virtual Deadline (recommended, mixed desktop+dev+gaming)
      - bpfland: Simpler priority model, pure gaming boxes
      - rusty: Multi-domain round-robin, heavy compile workloads (hurts game latency)
      - none: Stock CFS (no scx daemon)
    '';
  };
};
```

**Why nested** (`streaming = { enable = ...; }` rather than `streamingEnable`): existing options are flat, but nesting scales better once each feature grows sub-options (e.g., `streaming.encoder`, `wineTuning.shaderCache.path`). Acceptable introduction of a new nesting pattern.

### Phase 1: scx scheduler (smallest, lowest risk)

**Why first:** replaces existing dead code, no new user-visible surface, safe fallback built-in.

**Changes to `modules/constellation/gaming.nix`:**

1. Delete `modules/constellation/gaming.nix:360-361`:
   ```nix
   # System optimization
   system76-scheduler.enable = false; # Disabled - causes high context switches and freezing
   ```

2. Add inside top-level `config`, gated on scheduler != "none":
   ```nix
   services.scx = lib.mkIf (config.constellation.gaming.scheduler != "none") {
     enable = true;
     scheduler = "scx_${config.constellation.gaming.scheduler}";
     # scx daemon auto-unloads the BPF program on failure,
     # falling back to CFS — no manual intervention needed.
   };
   ```

3. Confirm `services.scx` exists in pinned nixpkgs-unstable (Phase 0 check below).

**No host changes.** raider inherits `scheduler = "lavd"` as the default.

### Phase 2: Wine/Proton tuning

**Changes to `modules/constellation/gaming.nix`**, all inside `lib.mkIf config.constellation.gaming.wineTuning.enable { ... }`:

1. **Load ntsync module:**
   ```nix
   boot.kernelModules = ["ntsync"];
   ```

2. **Udev rule for /dev/ntsync access** (merge into existing `services.udev.extraRules` at `modules/constellation/gaming.nix:132`):
   ```
   # ntsync: grant active login session access to Wine sync device
   KERNEL=="ntsync", MODE="0660", TAG+="uaccess"
   ```

3. **UMU Launcher + moonlight-qt** added to `environment.systemPackages` (around `modules/constellation/gaming.nix:241-307`):
   ```nix
   umu-launcher
   moonlight-qt  # client, pairs with Sunshine below
   ```

4. **Shader cache relocation and growth** via `environment.sessionVariables`:
   ```nix
   environment.sessionVariables = lib.mkIf config.constellation.gaming.wineTuning.enable {
     DXVK_STATE_CACHE_PATH = "/var/cache/dxvk";
     __GL_SHADER_DISK_CACHE_PATH = "/var/cache/gl-shaders";
     MESA_SHADER_CACHE_DIR = "/var/cache/mesa-shaders";
     DXVK_STATE_CACHE_MAX_ENTRIES = "2000000";
     MESA_SHADER_CACHE_MAX_SIZE = "2G";
     PROTON_USE_NTSYNC = "1";
   };
   ```

5. **tmpfiles for cache directories** — use sticky bit (1777) so multi-user is safe without needing to pick an owning group. Matches how `/tmp` handles the same problem:
   ```nix
   systemd.tmpfiles.rules = [
     "d /var/cache/dxvk 1777 root root - -"
     "d /var/cache/gl-shaders 1777 root root - -"
     "d /var/cache/mesa-shaders 1777 root root - -"
   ];
   ```

### Phase 3: Sunshine streaming

**Changes to `modules/constellation/gaming.nix`**, all inside `lib.mkIf config.constellation.gaming.streaming.enable { ... }`:

1. **Enable the service:**
   ```nix
   services.sunshine = {
     enable = true;
     autoStart = true;
     capSysAdmin = true;      # required for Wayland KMS capture
     openFirewall = false;    # we manage firewall ourselves, below
   };
   ```

2. **Tailscale-scoped firewall** — *alongside* the existing Steam ports at `modules/constellation/gaming.nix:504-508` (don't replace):
   ```nix
   networking.firewall.interfaces."tailscale0" = {
     allowedTCPPorts = [47984 47989 47990 48010];
     allowedUDPPorts = [47998 47999 48000 48002 48010];
   };
   ```

3. **Note in comment** that pairing is a one-time manual step:
   ```
   # Sunshine pairing: browse to http://raider.bat-boa.ts.net:47990 once,
   # set credentials, then pair Moonlight clients from the web UI.
   # Cannot be automated — skip if not needed.
   ```

### Phase 0: module availability check

Before writing any config, verify in a dev shell:

```bash
nix develop -c nix eval --no-warn-dirty \
  '.#nixosConfigurations.raider.options.services.sunshine.enable.default' 2>&1 | head
nix develop -c nix eval --no-warn-dirty \
  '.#nixosConfigurations.raider.options.services.scx.enable.default' 2>&1 | head
```

If either evaluates successfully, the module exists. If one errors, document the actual option path (may be e.g. `services.scx-scheds.*`) or fall back to manual systemd unit + package.

## Technical Considerations

### Architecture impacts

- **Module grows by ~80-100 lines.** `constellation.gaming` is already ~520 lines; this pushes it toward ~600. Still readable, no need for submodule split.
- **New nesting pattern** (`streaming.enable` / `wineTuning.enable`) — first nested sub-option in the module. Mirrored from constellation.services style.
- **`tailscale0` firewall interface scoping** — first use in a non-router host. Pattern is identical to `br-lan` scoping on router, just different interface.
- **Uaccess udev tag** — first use in this repo. `TAG+="uaccess"` makes systemd-logind grant access to the active session's uid automatically. Preferred over group-based access for desktop workstations.

### Performance implications

- **scx_lavd**: actively tuned for interactive workloads; measurable latency wins on game frame pacing under compile/background load (CachyOS upstream benchmarks).
- **ntsync**: 3-10% CPU-bound game perf improvement vs esync/fsync (Proton upstream benchmarks).
- **Shader cache 2G limit**: keeps AAA titles warm across launches; ~2GB of NVMe permanently consumed.
- **Sunshine**: adds a persistent daemon + VAAPI capture on game launch. Negligible overhead when idle.

### Security considerations

- **`capSysAdmin = true` on sunshine**: privilege elevation for KMS capture. Acceptable on a trusted single-user desktop, but call out in risks.
- **Tailscale-only firewall**: Sunshine binds `0.0.0.0`; firewall blocks everything except `tailscale0`. If Tailscale is down, Sunshine is unreachable (correct failure mode, not a security gap).
- **`uaccess` udev tag**: grants ntsync device access only to the active session (not daemon users). Correct scope.
- **Shader cache 1777**: world-writable but sticky — same trust model as `/tmp`. Compromised process on machine can poison another user's shader cache; acceptable on a single-user box but noted.
- **scx runs BPF programs in-kernel**: trust comes from nixpkgs packaging the scx_scheds binaries. No lower than running any other kernel module.

## System-Wide Impact

- **Interaction graph**: `constellation.gaming.enable = true` on raider currently pulls in kernel params, Steam, MangoHud, GameMode, ananicy-cpp, earlyoom, gamescope, and more. Adding streaming/wineTuning/scheduler gates each independently so the existing chain is untouched when they're disabled.
- **Error propagation**: scx daemon crash → falls back to CFS silently (documented upstream). Sunshine crash → systemd restarts. ntsync kernel module load failure → `boot.kernelModules` causes a boot warning but system continues (module is best-effort).
- **State lifecycle risks**: shader caches accumulate in `/var/cache` forever. No cleanup. Acceptable — same behavior as `~/.cache`. Sunshine stores pairing state in `/var/lib/sunshine` (standard); backed up via existing rustic if the host runs it (raider does not — storage does).
- **API surface parity**: the other gaming host is `g14`. It defaults to all three features on. G14 is a laptop — scx_lavd is fine, ntsync is fine, Sunshine is odd on a laptop that isn't plugged in. **Recommendation: g14 should opt out of `streaming.enable` explicitly** (addressed in acceptance criteria below).
- **Integration test scenarios**:
  1. Boot raider with scheduler=lavd, run steady stateful workload (compile while gaming) — verify scx_lavd loaded via `scx_loader --check` or journalctl.
  2. Launch a Proton game, `cat /proc/$PID/maps | grep ntsync` to confirm ntsync is used.
  3. Pair Moonlight from phone via Tailscale IP, stream Steam Big Picture for 60s — verify VAAPI encode, no firewall blocks from LAN non-Tailscale device.
  4. Drop Tailscale (`tailscale down`) and confirm Sunshine unreachable from LAN.
  5. Toggle `scheduler = "none"`, rebuild, verify CFS is active and no scx daemon running.

## Acceptance Criteria

### Functional

- [ ] `modules/constellation/gaming.nix` exposes `streaming.enable`, `wineTuning.enable`, `scheduler` options with defaults `true`/`true`/`"lavd"`.
- [ ] Dead `services.system76-scheduler.enable = false;` line and its comment are deleted.
- [ ] `services.scx` runs `scx_lavd` on raider after rebuild; verified via `systemctl status scx`.
- [ ] `/dev/ntsync` exists and is owned by the active session (not root) after login.
- [ ] `umu-launcher` and `moonlight-qt` are available in `$PATH`.
- [ ] `/var/cache/dxvk`, `/var/cache/gl-shaders`, `/var/cache/mesa-shaders` exist with mode 1777.
- [ ] `env | grep -E 'DXVK|MESA|NTSYNC'` inside a user shell shows the expected values.
- [ ] Sunshine systemd service is `active (running)` after rebuild.
- [ ] Sunshine is reachable on `http://raider.bat-boa.ts.net:47990` from a Tailscale peer.
- [ ] Sunshine is **not** reachable from a non-Tailscale LAN device at `http://raider.local:47990`.
- [ ] `just build raider` succeeds without evaluation errors.
- [ ] `just test raider` activates without requiring reboot for the non-kernel-module changes.
- [ ] Reboot required only for `boot.kernelModules = ["ntsync"]` pickup — follow with `just reboot raider`.

### Host config

- [ ] `hosts/g14/configuration.nix` explicitly sets `constellation.gaming.streaming.enable = false;` (laptop shouldn't run a streaming host by default). *Only required if g14 is actively being built/tested.*
- [ ] No changes to `hosts/raider/configuration.nix` required — all defaults apply.

### Quality gates

- [ ] `just fmt` passes (alejandra clean).
- [ ] `.github/workflows/build.yml` passes on raider/storage/cloud closures.
- [ ] Commit messages use conventional format, scope `modules` or `raider` (per `CLAUDE.md`).

### Pre-implementation gate

- [ ] Phase 0 module availability check passes for both `services.sunshine` and `services.scx`. If either fails, stop and reassess.

## Success Metrics

- Moonlight client can stream a Steam game from raider over Tailscale at ≥60fps with <50ms input latency on local network.
- `scx_lavd` reduces frame time 99p variance during background compile workload (subjective — compare feel before/after).
- Proton game cold-launch time reduces measurably after shader cache warm-up (DXVK HUD shader count stops growing after ~2 playthroughs).
- Zero regressions in existing gaming.nix behavior on raider.

## Dependencies & Risks

### Dependencies

- **nixpkgs-unstable @ 2026-04-07** (current flake.lock for raider, `flake-modules/hosts.nix:21`) must provide `services.sunshine` and `services.scx`. Both modules landed upstream in 2024, so pinned rev should be fine. **Phase 0 verifies.**
- **Xanmod kernel 6.14+** for in-kernel ntsync. Current gaming.nix pins `linuxPackages_xanmod_latest` (`modules/constellation/gaming.nix:40`) — fine, but if a future pin regresses below 6.14, ntsync will silently not load.
- **Tailscale** must be up for Sunshine to be reachable. Already enabled via `constellation.common`.

### Risks & Mitigations

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| `services.sunshine` module path changed / not in pinned rev | Low | High (blocks Phase 3) | Phase 0 check; fall back to manual systemd unit + `pkgs.sunshine` package |
| `services.scx` scheduler name format differs (e.g. `scx_lavd` vs `lavd`) | Medium | Low | Phase 0 check, adjust string prefix in module |
| ntsync kernel module not actually in xanmod pin | Low | Medium | `modprobe ntsync` manually to verify; if absent, pin a newer kernel or drop Phase 2a |
| scx_lavd crashes on raider workload | Low | Low | Auto-unloads to CFS; user can set `scheduler = "none"` and revert |
| Sunshine `capSysAdmin` breaks after a nixpkgs update | Low | High (stream capture dies) | Known Wayland capture fragility; document in commit message so future breakage is traceable |
| Shader cache 1777 mode creates cross-user poisoning surface | Very Low | Low | Single-user machine; acceptable. Revisit if raider gains multi-user |
| g14 accidentally runs a Sunshine host on battery | Medium | Low | Set `streaming.enable = false;` in g14 config as part of this PR |
| `tailscale0` interface doesn't exist at boot before Tailscale starts | Low | Low | Firewall rule is harmless when interface is absent; kicks in once interface appears |
| Pairing UX surprise — user doesn't know to visit `:47990` once | High | Low | Documented in module comment and commit message |

### Rollback

- Pure NixOS config change; `git revert` the commit and `just deploy raider`.
- For just-in-case: `constellation.gaming.streaming.enable = false;` etc. on raider as a fast knob without a revert.

## Sources & References

### Origin

- **Brainstorm:** [`docs/brainstorms/2026-04-12-bazzite-streaming-wine-scheduler-brainstorm.md`](../brainstorms/2026-04-12-bazzite-streaming-wine-scheduler-brainstorm.md) — key decisions carried forward:
  - Three-feature scope (streaming, wineTuning, scheduler); LACT/HDR/Decky explicitly deferred
  - Sunshine Tailscale-only exposure (no LAN, no Funnel)
  - scx_lavd as default with per-variant trade-off doc
  - Nested sub-options under `constellation.gaming`, default-on

### Internal references

- `modules/constellation/gaming.nix:9-35` — existing option shape to mirror
- `modules/constellation/gaming.nix:132-139` — existing `services.udev.extraRules` (where ntsync rule merges)
- `modules/constellation/gaming.nix:241-307` — `environment.systemPackages` (where umu/moonlight go)
- `modules/constellation/gaming.nix:360-361` — dead `system76-scheduler` line to delete
- `modules/constellation/gaming.nix:504-508` — existing Steam firewall block (sunshine rules go alongside)
- `flake-modules/hosts.nix:21` — raider on nixpkgs-unstable confirmation
- `hosts/router/services/caddy.nix:103` — existing `firewall.interfaces.*` scoping precedent (though on `br-lan`, not `tailscale0`)
- `hosts/raider/configuration.nix:254-256` — existing `environment.sessionVariables` for raider (GAMES_DIR)
- [`docs/brainstorms/2026-04-02-bazzite-system-features-brainstorm.md`](../brainstorms/2026-04-02-bazzite-system-features-brainstorm.md) — prior pass that landed PSI/IO scheduler/cpuVendor work; this plan builds on top.
- [`docs/brainstorms/2026-04-02-performance-osd-brainstorm.md`](../brainstorms/2026-04-02-performance-osd-brainstorm.md) — related; MangoHud preset wiring is out of scope here but tracked there.

### External references

- NixOS options — `services.sunshine.*` (verify in Phase 0)
- NixOS options — `services.scx.*` (verify in Phase 0)
- Linux 6.14 ntsync merge (merged upstream May 2024, Bazzite ships it)
- Bazzite handbook — Sunshine setup section (docs.bazzite.gg)
- CachyOS scheduler comparison — scx_lavd vs bpfland vs rusty trade-offs

## Implementation Checklist

A single-commit PR is fine since these three features are independent but all small. If scope balloons during implementation, split per phase.

1. [x] Phase 0: verified sunshine (`nixos/modules/services/networking/sunshine.nix`) and scx (`nixos/modules/services/scheduling/scx.nix`) exist in pinned unstable rev; scx_lavd present in scx.full package
2. [x] Phase 1: added `scheduler` option, wired `services.scx`, deleted dead sys76 line — `just build raider` green
3. [x] Phase 2: added `wineTuning` option, kernelModules + udev + env vars + tmpfiles + packages — `just build raider` green
4. [x] Phase 3: added `streaming` option, wired `services.sunshine` + tailscale0 firewall scoping — `just build raider` green
5. [x] `just fmt` (alejandra reformatted the packages list indentation; semantic unchanged)
6. [x] `hosts/g14/configuration.nix` set `streaming.enable = false;` — g14 cross-host build blocked on unrelated Attic NVIDIA fetch failure, not a config issue
7. [ ] `just test raider` (soft activation) — pending deploy
8. [ ] Manual: reboot raider (`just reboot raider`) for `boot.kernelModules = ["ntsync"]` to take effect
9. [ ] Manual: verify `/dev/ntsync` exists, `systemctl status scx`, `systemctl --user status sunshine` (note: sunshine runs as USER service, not system)
10. [ ] Manual: pair Moonlight on phone via `http://raider.bat-boa.ts.net:47990`
11. [ ] Commit — conventional format, scope `modules`, message references brainstorm
