# Brainstorm: Bazzite Features Pass 3 — Streaming, Wine Perf & Modern Scheduler

**Date:** 2026-04-12
**Status:** Draft
**Scope:** `modules/constellation/gaming.nix` (raider is the only consumer today)

## What We're Building

Third pass pulling features from Bazzite into our gaming stack. Prior passes covered GNOME UX ([2026-04-01](2026-04-01-bazzite-gnome-alignment-brainstorm.md)) and kernel/IO/memory tuning ([2026-04-02](2026-04-02-bazzite-system-features-brainstorm.md)). This pass targets three remaining gaps:

1. **Game streaming** — Sunshine as a first-class systemd service, Tailscale-scoped.
2. **Wine/Proton performance** — `ntsync` kernel module, UMU Launcher, DXVK/VKD3D shader cache tuning.
3. **Modern scheduler** — `scx_sched_ext` BPF schedulers to replace the disabled-because-buggy `system76-scheduler` (`modules/constellation/gaming.nix:361`).

Everything lands behind new sub-options on `constellation.gaming`, default-enabled so raider inherits automatically but future hosts (g14) can opt out.

## Why This Approach

- **Sunshine** is the single biggest Bazzite-branded feature not yet pulled in. It turns raider into a low-latency game host reachable from phone/TV/laptop via Moonlight. Integrates cleanly as a NixOS service (`services.sunshine`), fits our Tailscale-first network model, and requires no desktop changes.
- **ntsync/UMU/shader cache** are pure performance/compat wins with no UX surface. ntsync in particular is the synchronization primitive Wine/Proton has been moving to for years — finally upstream in 6.14, xanmod ships it, we just need the `ntsync` module loaded and `/dev/ntsync` permissions via udev.
- **scx schedulers** are the modern replacement for the `system76-scheduler` approach. The old scheduler was disabled because it caused "high context switches and freezing" (`modules/constellation/gaming.nix:361`). Leaving nothing in its place means we inherit stock CFS, which is fine but not tuned for gaming. CachyOS and Bazzite both ship `scx_lavd` as default now; it's BPF-based and much more robust than the sys76 userspace daemon.
- **Sub-options, default-on** mirrors the pattern already in the module (`kernelOptimizations`, `gamingMode`, `cpuVendor`, `performanceOsd`). Keeps raider's config untouched while giving other hosts escape hatches.

## Key Decisions

### 1. Sunshine game streaming

**New option:** `constellation.gaming.streaming.enable` (default `true`).

**Module shape:**
```nix
services.sunshine = {
  enable = true;
  autoStart = true;
  capSysAdmin = true;            # needed for KMS capture on Wayland
  openFirewall = false;          # we manage firewall ourselves, Tailscale-only
};

# Tailscale-only exposure: open Sunshine ports on tailscale0 only
networking.firewall.interfaces."tailscale0".allowedTCPPorts = [ 47984 47989 47990 48010 ];
networking.firewall.interfaces."tailscale0".allowedUDPPorts = [ 47998 47999 48000 48002 48010 ];
```

**Encoder:** AMD AMF via VAAPI on the RX 6650 XT (RDNA2 supports H.264/HEVC encode). Fallback to software if that breaks. The Intel iGPU (`/dev/dri/renderD129`) is already claimed by Stash for decode — don't cross-wire.

**Client packages:** ship `moonlight-qt` too so raider can *receive* streams from other hosts (useful for cloud gaming setups).

**Pairing flow:** document in a README-style comment block. Pairing is a one-time interactive step (`sunshine` web UI on `:47990`); cannot be fully automated, but Tailscale exposure makes it safe.

**Trade-off called out:** Sunshine wants `CAP_SYS_ADMIN` on Wayland for KMS capture. The nixpkgs module handles this, but it's a capability-elevation worth knowing about. We're OK with it on a trusted desktop.

**Note on `constellation.services` registry:** raider doesn't currently register with the service registry (which is storage/cloud focused via Cloudflare/Caddy). Sunshine lives outside that stack — direct Tailscale access, not via the media gateway.

### 2. Wine/Proton performance

**New option:** `constellation.gaming.wineTuning.enable` (default `true`).

**a) ntsync kernel module**

```nix
boot.kernelModules = [ "ntsync" ];

services.udev.extraRules = ''
  KERNEL=="ntsync", MODE="0660", TAG+="uaccess"
'';
```

Xanmod 6.14+ has the module. `uaccess` tag grants the active login session access without needing a group. Wine/Proton 9.x+ auto-detect and use it.

**Environment variable** (for Proton builds that don't auto-detect):
```nix
environment.sessionVariables = {
  PROTON_USE_NTSYNC = "1";
};
```

**b) UMU Launcher**

Add `umu-launcher` to `environment.systemPackages`. This is now the upstream for Lutris/Heroic/Bottles Proton runs — bundling it explicitly means all three frontends use the same shared runtime and Proton-GE installs, reducing duplication.

**c) Shader cache tuning**

```nix
environment.sessionVariables = {
  # Keep shader caches on the fast Solidigm 2TB NVMe instead of ~/.cache
  DXVK_STATE_CACHE_PATH = "/var/cache/dxvk";
  __GL_SHADER_DISK_CACHE_PATH = "/var/cache/gl-shaders";
  MESA_SHADER_CACHE_DIR = "/var/cache/mesa-shaders";

  # Larger caches (default 128MB → 2GB) so AAA games don't thrash
  DXVK_STATE_CACHE_MAX_ENTRIES = "2000000";
  MESA_SHADER_CACHE_MAX_SIZE = "2G";
};

systemd.tmpfiles.rules = [
  "d /var/cache/dxvk 0755 root root - -"
  "d /var/cache/gl-shaders 0755 root root - -"
  "d /var/cache/mesa-shaders 0755 root root - -"
];
```

**Called out:** `/var/cache` is already on the NVMe root. We're just moving caches out of `~/.cache` so they're preserved across user reinstalls and benefit multi-user. If this turns out to cause permission pain, fall back to `XDG_CACHE_HOME` defaults.

### 3. scx_sched_ext scheduler

**New option:** `constellation.gaming.scheduler` — `enum [ "none" "lavd" "bpfland" "rusty" ]`, default `"lavd"`.

**Recommendation per use case** (user asked for this):

| Variant | Best for | Why |
|---|---|---|
| **`scx_lavd`** | Raider's mixed desktop + gaming + dev | Latency-Aware Virtual Deadline. Actively tuned for interactive workloads (games, browsers, IDEs). CachyOS default; what Bazzite ships. Handles compile spikes without starving the game. |
| **`scx_bpfland`** | Pure gaming boxes (Steam Deck-like) | Simpler priority model, smaller footprint. No advantage over lavd on a dev workstation. |
| **`scx_rusty`** | Heavy parallel dev (big compiles, no games) | Multi-domain round-robin; actively hurts gaming latency because it's not interactivity-aware. |

**Recommendation for raider:** `scx_lavd`. It's the closest match to the "gaming + dev workstation" workload and is what CachyOS/Bazzite stabilized on.

**Module shape:**
```nix
services.scx = {
  enable = config.constellation.gaming.scheduler != "none";
  scheduler = "scx_${config.constellation.gaming.scheduler}";
};
```

**Kernel requirement:** sched_ext needs kernel 6.12+, which xanmod already provides. No extra kernel work needed.

**Safety net:** if scx crashes it falls back to CFS automatically (the daemon unloads the BPF program). System stays responsive. Worth documenting in a comment.

**Tangential cleanup:** delete the dead `services.system76-scheduler.enable = false;` line now that we have a replacement. Comment explaining why it's gone.

## What We're NOT Doing

- **Decky Loader / gamescope-session GDM entry** — User deprioritized; not a Big Picture user on this box.
- **HDR in gamescope** — Deferred until we know the monitor's HDR capability. Easy to add later as `--hdr-enabled --hdr-itm-enable` in the existing `programs.gamescope.args`.
- **LACT** — CoreCtrl works, no active pain point. Revisit if fan curves / undervolt are needed for the 6650 XT.
- **MangoHud preset file** — The module already claims "Steam Deck-style preset cycling" but ships only `MANGOHUD=1`. A separate small fix, not in scope here. (Note for future: there's a `2026-04-02-performance-osd-brainstorm.md` already.)
- **Waydroid / Greenlight / OpenTabletDriver** — Low priority grab bag.
- **Tailscale Funnel for Sunshine** — Explicitly rejected (public exposure of a game streaming host is a sharp edge).
- **Public-facing port exposure** — raider remains LAN+Tailscale only.
- **Auto-pairing Sunshine** — Not possible; one-time manual step.

## Open Questions

_None — all scoping questions resolved in the brainstorming dialogue._

## Resolved Questions

1. **Which categories to pull?** → Streaming (Sunshine), Wine/Proton perf (ntsync/UMU/shaders), scx schedulers. Skipped: LACT/HDR/MangoHud, Decky/gamescope-session, extras.
2. **Sunshine network exposure?** → Tailscale-only (firewall scoped to `tailscale0`). No LAN, no Funnel.
3. **Module shape?** → Sub-options under `constellation.gaming`, default-on, so other hosts can opt out.
4. **scx variant?** → `scx_lavd` as default for raider (dev + gaming mix); document trade-offs for bpfland/rusty in case other hosts adopt.

## Next: Planning

Run `/ce:plan docs/brainstorms/2026-04-12-bazzite-streaming-wine-scheduler-brainstorm.md` to produce the implementation plan. Expected deliverables:

- `modules/constellation/gaming.nix` — add `streaming`, `wineTuning`, `scheduler` options
- Verify `services.sunshine` and `services.scx` modules exist in current nixpkgs (they should, but flake input lock matters)
- Build & activate on raider via `just test raider` before committing
