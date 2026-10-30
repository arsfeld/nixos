# raider: isolate Claude agent work in `agents.slice`

## Problem

Claude Code tasks on raider (rustc, cargo, beam.smp, devenv) make the desktop and
games stutter and occasionally freeze for seconds. Measured on 2026-10-30 with
three agent sessions busy: CPU pressure `some avg10=80`, memory pressure
`full avg10=4`, 14 GB swapped out (part of it to the disk swapfile on
`/mnt/games`).

Why nothing currently protects the desktop:

- **Interactive `claude` runs in login session scopes.** zellij started over SSH
  lands in `user-1000.slice/session-N.scope`, a sibling of `user@1000.service`
  (DE, games) at equal `cpu.weight=100`. With several busy scopes the desktop is
  one share among N.
- **nice does not cross cgroups.** That work already runs at nice 12, which only
  orders it against processes in the same cgroup, never against the desktop.
- **`claude-rc-*` services share `app.slice` with GNOME apps and Steam**, with no
  CPU, I/O or memory limits.
- **`gaming-boost` only touches `nix-daemon`.** Agent work keeps every P-core
  while a game runs.

## Design

### 1. `agents.slice` (`home/home.nix`, raider only)

Defined next to `claudeRcServices` under the same `hostname == "raider"` guard:

```
systemd.user.slices.agents.Slice = {
  CPUWeight = 20;
  IOWeight = 20;
  MemoryHigh = "12G";
};
```

- Weights are work-conserving: agents still use every idle core; they lose only
  when the desktop wants CPU or I/O.
- `MemoryHigh` without `MemoryMax`: past 12 GB the slice is throttled and
  reclaimed from first, so pressure lands on agent builds rather than pushing
  the desktop into swap. Nothing is OOM-killed by this limit.

All Claude work enters the slice two ways:

- **`claude-rc-*` units** get `Service.Slice = "agents.slice"`. Remote-control
  sessions and the devenvs they start are children and inherit it.
- **The `claude` script** (the `llmAgentScripts` entry that runs
  `nix run github:numtide/llm-agents.nix#claude`) execs through
  `systemd-run --user --scope --slice=agents.slice --collect --quiet --` on
  raider. This covers `cc`, `claude-worktree`, zellij panes and plain terminals,
  which all resolve `claude` via PATH. If `/proc/self/cgroup` already contains
  `/agents.slice/`, the script execs `nix run` directly, so invocations from
  inside a `claude-rc-*` unit do not create nested scopes. Other hosts keep the
  plain script.

### 2. Gaming hook (`modules/constellation/gaming.nix`)

New shared option:

```
constellation.gaming.backgroundUserSlices  # listOf str, default []
```

User-manager slices that yield to a running game. raider sets
`["agents.slice"]`.

The `gaming-boost` script already runs as the user under gamemoded. With
`backgroundCpus` set, `on` additionally runs, per listed slice:

```
systemctl --user set-property --runtime <slice> AllowedCPUs=<backgroundCpus>
```

and `off` resets it with `AllowedCPUs=`. These are user units, so no polkit rule
is needed; `--runtime` means nothing survives a reboot, matching the existing
`nix-daemon` path. On raider that confines agents to E-cores 8-15 for the
duration of a game, on top of their permanent low weight.

## Verification

1. `just build raider` succeeds.
2. After `just deploy raider`, both a `claude-rc-*` session and a `cc`-launched
   session show `agents.slice` in `/proc/<pid>/cgroup`.
3. `systemctl --user show agents.slice -p CPUWeight,IOWeight,MemoryHigh` shows
   20 / 20 / 12G.
4. With a mydia `cargo build` saturating the slice,
   `user@1000.service/session.slice/cpu.pressure` stays near zero and the desktop
   stays responsive.
5. `gamemoderun sleep 10`: `systemctl --user show agents.slice -p AllowedCPUs`
   reads `8-15` during the run and empty afterwards.

## Out of scope

- `nix build`s requested by agents run in `nix-daemon` (`system.slice`), outside
  the agent slice. `gaming-boost` already confines it during games.
- The disk swapfile on `/mnt/games`.
- Re-enabling sched_ext (scx_lavd has an ABI mismatch on Linux 7.x).
- Other session scopes (non-Claude SSH shells), which keep their default weight.
