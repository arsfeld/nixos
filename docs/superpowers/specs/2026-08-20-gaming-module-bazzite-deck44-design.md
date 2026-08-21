# Gaming module: adopting Bazzite Deck 44 lessons

Date: 2026-08-20
Scope: `modules/constellation/gaming.nix`, `hosts/raider/configuration.nix`

## Motivation

Bazzite's Deck 44 release moved several things we already approximate onto better
mechanisms. Four of them are worth copying. The rest of the release (OGC kernel,
handheld stack, VRAM-overcommit booster daemons) is either unpackaged in nixpkgs
or irrelevant to a desktop, and is explicitly out of scope.

The OGC kernel is **not** in nixpkgs — there is no `linuxPackages_ogc` attribute and
no third-party flake packaging it. OGC's stated policy is to upstream patches rather
than maintain a fork, so xanmod remains the right choice.

## Changes

### A. bpftune replaces the static network sysctls

`services.bpftune.enable = true`, and delete the hand-set network sysctls from
`boot.kernel.sysctl`:

- `net.core.rmem_default`, `net.core.rmem_max`
- `net.core.wmem_default`, `net.core.wmem_max`
- `net.core.netdev_max_backlog`, `net.core.optmem_max`
- `net.ipv4.tcp_rmem`, `net.ipv4.tcp_wmem`
- `net.ipv4.tcp_keepalive_{time,intvl,probes}`
- `net.ipv4.tcp_mtu_probing`

bpftune's premise is that statically sized buffers are wrong under changing load;
keeping both means the declared config no longer describes the running system.

Retained deliberately: `net.core.default_qdisc = cake`,
`net.ipv4.tcp_congestion_control = bbr`, `tcp_fastopen`, `tcp_syncookies`, and every
`vm.*`/`fs.*`/`kernel.*` knob. bpftune ships a congestion tuner; if it proves to
fight `bbr` we drop `bbr` too, but the declared default stays until observed otherwise.

Note: Bazzite's bpftune carries game-detection patches that are not in upstream
`bpftune 0.4-2`. What we get is generic TCP/neigh autotuning.

### B. gaming-boost replaces the gaming-mode sledgehammer

Deleted: `systemd.services.gaming-mode` and the `gaming-on`/`gaming-off` shell
aliases. That unit ran `pkill -f "python|pip"`, stopped postgres/libvirt/containers,
and did `echo 3 > /proc/sys/vm/drop_caches` — which throws away the page cache the
game is about to need. It also duplicated and undermined ananicy-cpp, which already
idle-classes build tools correctly.

Replacement, following Bazzite's move to foreground resource boosting
(`dmemcg-booster`, `uresourced-dmemcg`):

1. `systemd.services.gaming-boost` — `Type=oneshot`, `RemainAfterExit=yes`.
   Start applies `CPUWeight=20 IOWeight=20` (plus `AllowedCPUs=` when
   `backgroundCpus` is set) to `nix-daemon.service` via
   `systemctl set-property --runtime`. Stop assigns the same properties empty,
   which resets them.
2. A `gaming-boost` wrapper script wired to `programs.gamemode.settings.custom.start`
   and `.end`.
3. One polkit rule letting the `gamemode` group start and stop that unit without
   authentication.

**Why `AllowedCPUs` and not just `CPUWeight`.** `nix-daemon.service` lives in
`system.slice`; a game lives in `user.slice`. `CPUWeight` only arbitrates between
siblings sharing a parent cgroup, so lowering nix-daemon's weight does *not* make
builds yield to the game — it only reorders nix-daemon against other system.slice
units. `AllowedCPUs` is an absolute confinement and works regardless of hierarchy.

**Why a system unit instead of an inline `set-property` in the hook.** `gamemoded`
runs as a *user* service (`systemd.user.services.gamemoded`), so its custom scripts
cannot set properties on a system unit. The oneshot plus polkit rule is the
privilege bridge.

**Trigger caveat.** The hook only fires when a game actually invokes gamemode
(`gamemoderun %command%`; Lutris/Heroic/Bottles do this by default, bare Steam does
not). This is the same gate that already governs `gpu.amd_performance_level = "high"`,
so it is not a new limitation.

### C. LACT replaces corectrl

`services.lact.enable = true`; remove `programs.corectrl.enable` and the `corectrl`
group. `lactd` applies saved fan/power/clock profiles at boot without a GUI session
or a polkit prompt; corectrl only applies settings while its tray app runs.

Not gated on `cpuVendor` — LACT supports NVIDIA, so blackbird benefits too.

`hardware.amdgpu.overdrive.enable` is deliberately left off. It is required for
custom fan curves and undervolting but adds `amdgpu.ppfeaturemask=0xffffffff` at
boot; that is a separate opt-in decision.

gamemode's `gpu.amd_performance_level = "high"` stays. It is transient and only
applies for the duration of a game.

### D. scx-loader replaces static scx

`services.scx` becomes `services.scx-loader` with
`config.default_sched = "scx_${cfg.scheduler}"`. The nixpkgs module asserts the two
cannot be enabled simultaneously. `scx_lavd` is present in `scx.rustscheds`.

**No scheduler switching is wired into the gaming hook.** `scx_lavd --help` states
that `--autopilot` — which automatically decides performance/powersave/balanced from
system load — "is a default mode" when no option is given, and it is mutually
exclusive with `--performance`. Switching to scx-loader's Gaming mode would largely
duplicate autopilot while costing a BPF unload/reload stall at both game start and
exit. The swap is still worth it for the DBus interface
(`org.scx.Loader.SwitchScheduler`, polkit action `org.scx.loader.manage-schedulers`),
which makes manual or future tooling-driven switching possible.

## New option

`constellation.gaming.backgroundCpus` — `nullOr str`, default `null`. The CPU set
background build work is confined to while a game runs.

raider sets `"8-15"`: its i5-12500H is 4 P-cores at 4500 MHz (CPUs 0-7, SMT) plus
8 E-cores at 3300 MHz (CPUs 8-15), so builds land on E-cores and P-cores stay clear.
blackbird leaves it `null` — Zen 4 has no E-cores.

## Verification

Mechanism was probed on raider against a throwaway transient unit before adoption:
`set-property --runtime AllowedCPUs=8-15` wrote `cpuset.cpus=8-15`, and assigning the
properties empty reset the cgroup file. The `cpuset` controller is present in
`/sys/fs/cgroup/cgroup.subtree_control`.

1. `nix build .#nixosConfigurations.raider.config.system.build.toplevel`
2. After deploy: `bpftune`, `scx_loader`, `lactd` all active; `scx.service` absent.
3. Launch a title under `gamemoderun`; confirm
   `systemctl show nix-daemon.service -p AllowedCPUs` reports `8-15` during play and
   empty after exit.

## Out of scope

- **OGC kernel** — not packaged for Nix; stay on xanmod.
- **VRAM overcommit boosters** — the `dmem` cgroup controller *is* live on raider's
  kernel, but `dmemcg-booster` / `uresourced-dmemcg` are not packaged.
- **Handheld stack** (InputPlumber, SteamOS-Manager, PowerStation, OpenGamepadUI) —
  packaged in nixpkgs but no payoff on a desktop.
- **`vulkan-low-latency-layer`, Cardwire** — not in nixpkgs.
- **CI supply-chain hardening** (SHA-pinned actions, `permissions: {}`) — a real
  lesson from the same release, but it belongs to `.github/workflows/`, not here.
