# Split blackbird's and raider's configuration.nix — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move each concern in `hosts/{blackbird,raider}/configuration.nix` into its own sibling file, leaving both system closures byte-identical.

**Architecture:** Each concern becomes one flat file in `hosts/<host>/`, imported from `configuration.nix`. Code and comments move verbatim. Placement follows the merge-order rules in the spec. Proof is an identical toplevel `drvPath` before and after.

**Tech Stack:** NixOS modules, flake-parts, alejandra.

Spec: `docs/superpowers/specs/2026-10-31-split-host-configurations-design.md`.

## Global Constraints

- Pure refactor: toplevel `drvPath` for each host must equal its pre-change value exactly. A difference is fixed, never accepted.
- Never split a list-valued option across files. `environment.systemPackages` and `boot.kernelParams` stay whole in `configuration.nix`.
- Move comments verbatim with their code. Edit a comment only where it points at a location that moved ("below" → "in nvidia.nix").
- Commit straight to master. No branches, no worktrees.
- Commit types/scopes: `refactor(blackbird): …`, `refactor(raider): …`. Never mention Claude.
- New files must be `git add`ed before any `nix eval`/`nix build`. The flake only sees tracked files.
- The working tree has someone else's uncommitted edits to `modules/constellation/desktop.nix` and a pantheon-dock test. Never stage them. Always evaluate a **committed revision** (`git+file://$PWD?rev=<sha>`), so those edits cannot move either drvPath.
- Line numbers below refer to the files as of commit `739ade31`. Read the file first. If the lines have drifted, match on content.

## Merge-order facts this plan relies on

Checked with `lib.evalModules`: when a module defines a list option and also imports `[a b]` that define it, the merged order is `b a module`. Imports merge first, in reverse import order, and the importing file's own definition comes last. A file's subtree stays contiguous among all modules, so moving a definition *within* `hosts/<host>/` never changes its order relative to `modules/`.

Shared helper used by both tasks (run from the repo root):

```bash
drv() { # drv <host> <rev>
  nix eval --raw "git+file://$PWD?rev=$2#nixosConfigurations.$1.config.system.build.toplevel.drvPath"
}
```

---

### Task 1: Split blackbird

**Files:**
- Create: `hosts/blackbird/dgpu-power.nix`, `hosts/blackbird/nvidia.nix`, `hosts/blackbird/asus.nix`, `hosts/blackbird/audio.nix`, `hosts/blackbird/fingerprint.nix`, `hosts/blackbird/power.nix`
- Modify: `hosts/blackbird/configuration.nix`

**Interfaces:**
- Produces: `hosts/blackbird/dgpu-power.nix`, a function `{writeShellScriptBin, nvidia}: <derivation>`, called identically from `configuration.nix` and `nvidia.nix` as `pkgs.callPackage ./dgpu-power.nix {nvidia = config.hardware.nvidia.package;}`.

- [ ] **Step 1: Record the baseline**

```bash
BASE=$(git rev-parse HEAD)
drv blackbird $BASE | tee /tmp/blackbird.before
```
Expected: one `/nix/store/…-nixos-system-blackbird-….drv` path.

- [ ] **Step 2: Create `dgpu-power.nix`**

The comment is today's lines 29–39, with "the nvidia-unclamp-tgp unit below" changed to "the nvidia-unclamp-tgp unit in nvidia.nix". The script body is lines 41–65, with `${config.hardware.nvidia.package.bin}` changed to `${nvidia.bin}`. Every other byte of the script text stays the same. Re-indenting inside `''…''` is safe, because Nix strips the common indent.

```nix
# The dGPU's enforced power limit in the top bar: the number the
# nvidia-unclamp-tgp unit in nvidia.nix exists to change, and which has been
# seen reverting to 30 W mid-session. Printed for gnomeExtensions.executor,
# which runs it through `bash -c` on an interval.
#
# `nvidia-smi --query-gpu=power.limit` returns [N/A] on this GPU (measured on
# driver 595.71.05), so the limits have to come from the -q report, where they
# are populated. There "Current Power Limit" appears twice -- under GPU Power
# Readings and again under Module Power Readings, which is all N/A here -- so
# awk windows on the first block rather than grepping. P-state, memory clock
# and the SW Power Cap flag do work through --query-gpu.
#
# Called from both configuration.nix (systemPackages) and nvidia.nix (the
# Executor command); identical calls yield one derivation.
{
  writeShellScriptBin,
  nvidia,
}:
writeShellScriptBin "dgpu-power" ''
  smi=${nvidia.bin}/bin/nvidia-smi

  limits=$("$smi" -q -d POWER 2>/dev/null | awk '
    /GPU Power Readings/    { gpu = 1 }
    /Module Power Readings/ { gpu = 0 }
    gpu && /Current Power Limit/ { cur = $(NF - 1) }
    gpu && /Default Power Limit/ { print cur, $(NF - 1); exit }
  ')
  read -r cur def <<<"$limits"
  # Driver not loaded, or the fields read N/A: print nothing, not noise.
  case "$cur$def" in "" | *[!0-9.]*) exit 0 ;; esac

  IFS=, read -r pstate mem cap <<<"$(
    "$smi" --query-gpu=pstate,clocks.mem,clocks_event_reasons.sw_power_cap \
           --format=csv,noheader,nounits 2>/dev/null | tr -d ' '
  )"

  cap_flag=""
  [ "$cap" = Active ] && cap_flag=" cap"

  if [ "$cur" = "$def" ]; then
    printf '%.0fW %s %sMHz%s\n' "$cur" "$pstate" "$mem" "$cap_flag"
  else
    printf '! %.0f/%.0fW %s %sMHz%s\n' "$cur" "$def" "$pstate" "$mem" "$cap_flag"
  fi
''
```

- [ ] **Step 3: Create `nvidia.nix`**

```nix
{
  config,
  lib,
  pkgs,
  ...
}: let
  # <today's lines 17-27 verbatim: the Astra Monitor comment and `dgpu = {...};`>

  dgpu-power = pkgs.callPackage ./dgpu-power.nix {nvidia = config.hardware.nvidia.package;};
in {
  # <today's lines 199-342 verbatim: nvidiaPersistenced, nvidia-unclamp-tgp,
  #  and the Astra/Executor programs.dconf.profiles.user.databases block>

  # <today's lines 480-516 verbatim: the NVIDIA suspend/resume comment and
  #  systemd.services.nvidia-resume>
}
```

In the moved text, the comment at today's line 300 ("Both extensions come from constellation.desktop.gnome.gpuMonitor above.") becomes "…gnome.gpuMonitor in configuration.nix.".

- [ ] **Step 4: Create `asus.nix`**

```nix
{pkgs, ...}: {
  # <today's lines 344-349 verbatim: asus-shutdown restartIfChanged>

  # <today's lines 351-380 verbatim: supergfxd and asusd with fanCurvesConfig>

  # <today's lines 518-535 verbatim: GA401IU keyboard backlight rebind sleep hook>
}
```

- [ ] **Step 5: Create `audio.nix`**

```nix
{pkgs, ...}: {
  # <today's lines 382-439 verbatim: pipewire, home-manager easyeffects
  #  xdg.dataFile entries (./easyeffects-*.json paths still resolve, same dir),
  #  easyeffectsLegacyCleanup activation script, easyeffects user service>
}
```

- [ ] **Step 6: Create `fingerprint.nix`**

```nix
{
  config,
  lib,
  pkgs,
  ...
}: {
  # <today's lines 537-587 verbatim: services.fprintd and the
  #  gdm-fingerprint modulePath override>
}
```

- [ ] **Step 7: Create `power.nix`**

```nix
{...}: let
  gsettingsOverrides = ''
    [org.gnome.desktop.interface]
    text-scaling-factor=1.25

    [org.gnome.settings-daemon.plugins.power]
    sleep-inactive-ac-type='nothing'
    sleep-inactive-battery-type='nothing'
  '';
in {
  # <today's lines 115-127 verbatim: the scaling/gsd-power comment and both
  #  extraGSettingsOverrides assignments>

  # <today's lines 454-478 verbatim: power-profiles-daemon comment + enable,
  #  plain-S3 comment + services.logind.settings.Login>
}
```

In the moved text, the comment at today's line 120 ("Lid/power-button suspend still works via logind below.") stays accurate, because logind is below it in the same file.

- [ ] **Step 8: Rewrite `configuration.nix`**

Replace lines 1–71 (args, the `let` block, imports) with:

```nix
{
  config,
  pkgs,
  ...
}: let
  # Defined in dgpu-power.nix; nvidia.nix makes the identical call for its
  # Executor command. Listed here so systemPackages keeps its order.
  dgpu-power = pkgs.callPackage ./dgpu-power.nix {nvidia = config.hardware.nvidia.package;};
in {
  imports = [
    ./hardware-configuration.nix
    ./disko-config.nix
    ./nvidia.nix
    ./asus.nix
    ./audio.nix
    ./fingerprint.nix
    ./power.nix
  ];
```

Then delete every block moved in Steps 3–7: lines 115–127, 199–342, 344–380, 382–439, 454–478, 480–516, 518–535 and 537–587. What remains is the ntfy secret, the `constellation` block, hostname, `permittedInsecurePackages`, `systemPackages` (still listing `dgpu-power` last, on its own line), the bootloader comment and settings, `kernelParams`, NetworkManager and its group, incus, firewall and `stateVersion`, in their current order.

If `lib` or `inputs` is no longer referenced, drop it from the argument list. `grep -n 'lib\.\|inputs' hosts/blackbird/configuration.nix` should print nothing.

- [ ] **Step 9: Check nothing was lost or duplicated**

```bash
git show $BASE:hosts/blackbird/configuration.nix | grep -v '^\s*$' | sort > /tmp/bb.old
cat hosts/blackbird/{configuration,dgpu-power,nvidia,asus,audio,fingerprint,power}.nix | grep -v '^\s*$' | sort > /tmp/bb.new
diff /tmp/bb.old /tmp/bb.new
```
Expected: only the new headers and `let`/`in`/import lines, the two edited "below"/"above" comments, the `${nvidia.bin}` line, re-indentation of the script, and the `dgpu-power` callPackage lines. No moved setting line may appear on the `<` side alone.

- [ ] **Step 10: Format, stage, commit**

```bash
just fmt
git add hosts/blackbird/
git status --short   # must show only hosts/blackbird/ staged; desktop.nix stays unstaged
git commit -m "refactor(blackbird): split configuration.nix by concern"
```

- [ ] **Step 11: Verify the drvPath is identical**

```bash
drv blackbird $(git rev-parse HEAD) > /tmp/blackbird.after
diff /tmp/blackbird.before /tmp/blackbird.after && echo IDENTICAL
```
Expected: `IDENTICAL`.

If they differ, find the cause:
```bash
nix run nixpkgs#nix-diff -- $(cat /tmp/blackbird.before) $(cat /tmp/blackbird.after)
```
Fix the placement (most likely a list whose order moved, or a script byte changed in Step 2), then `git commit --amend --no-edit` and repeat this step. Do not push until it says `IDENTICAL`.

---

### Task 2: Split raider

**Files:**
- Create: `hosts/raider/stash.nix`, `hosts/raider/niks3.nix`, `hosts/raider/backup.nix`, `hosts/raider/nix-builds.nix`, `hosts/raider/no-suspend.nix`
- Modify: `hosts/raider/configuration.nix`

**Interfaces:**
- Consumes: nothing from Task 1.
- Produces: nothing other tasks use.

Two placement rules are specific to raider:
- `no-suspend.nix` goes **first** in `imports`. Its `programs.dconf.profiles.user.databases` entry was the host's own definition, which merges last. `appearance.nix` also defines that list, and the first import merges last among imports.
- `./niks3.nix` takes the **exact slot** in `imports` where `inputs.niks3.nixosModules.niks3-auto-upload` sits today (between `./project-vms.nix` and `./zellij-socket-watch.nix`). It imports that module itself, so the upstream module keeps its position relative to its siblings.

- [ ] **Step 1: Record the baseline**

```bash
BASE=$(git rev-parse HEAD)
drv raider $BASE | tee /tmp/raider.before
```

- [ ] **Step 2: Create `stash.nix`**

```nix
{
  config,
  lib,
  pkgs,
  ...
}: {
  # <today's lines 28-36 verbatim: stash-jwt-secret and stash-session-secret>

  # <today's lines 195-287 verbatim: stashapp-tools/stashPython overlay,
  #  services.stash, and the systemd.services.stash override>
}
```

- [ ] **Step 3: Create `niks3.nix`**

```nix
{
  config,
  inputs,
  ...
}: {
  imports = [inputs.niks3.nixosModules.niks3-auto-upload];

  # <today's lines 46-86 verbatim: the niks3-api-token comment + secret and
  #  the auto-upload comment + services.niks3-auto-upload>

  # `just deploy` phase 1 pushes through nix-fast-build --niks3-server,
  # whose upload worker runs `niks3 push` as this user. Pointing it at the
  # sops secret keeps a single copy of the token on disk.
  environment.sessionVariables.NIKS3_AUTH_TOKEN_FILE = config.sops.secrets."niks3-api-token".path;
}
```

The comment in `configuration.nix` lines 432–434 moves here, as shown.

- [ ] **Step 4: Create `backup.nix`**

```nix
{config, ...}: {
  # Interval-based scheduler matches laptop usage: runs ~24h after the
  # last successful run, catches up once after long suspensions
  # instead of stacking skipped cron entries.
  constellation.backrest = {
    enable = true;
    # <today's lines 139-180 verbatim: repos.storage and plans.system>
  };
}
```

- [ ] **Step 5: Create `nix-builds.nix`**

```nix
{lib, ...}: {
  # <today's lines 292-324 verbatim: boot.binfmt, the extra-platforms comment
  #  and mkForce, the cores = 4 comment and setting, and the user slice /
  #  nix-daemon MemoryHigh block>
}
```

- [ ] **Step 6: Create `no-suspend.nix`**

```nix
{lib, ...}: {
  # <today's lines 370-427 verbatim: "Disable suspend/hibernate" logind
  #  settings, masked sleep services and targets, powerManagement block,
  #  and the noIdleSuspend programs.dconf.profiles let/in>
}
```

In the moved text, the dconf comment at today's line 404 ("The masked targets above already make it fail…") stays accurate, because the targets are above it in the same file.

- [ ] **Step 7: Rewrite `configuration.nix`**

Replace the `imports` list with:

```nix
  imports = [
    # First, so its dconf databases still merge after appearance.nix's.
    ./no-suspend.nix
    ./hardware-configuration.nix
    ./disko-config.nix
    ./fan-control.nix
    ./appearance.nix
    ./fontconfig.nix
    ./harmonia.nix
    ./samba.nix
    ./docker.nix
    ./project-vms.nix
    ./niks3.nix
    ./zellij-socket-watch.nix
    ./usb-reset.nix
    ./devenv-reaper.nix
    ./stash.nix
    ./backup.nix
    ./nix-builds.nix
  ];
```

Then:
- Delete lines 28–36, 46–86, 195–287, 292–324 and 370–427.
- In the `constellation = { … };` block, delete `backrest = { … };` (lines 134–181) and keep `desktop`, `gaming` and `development`.
- Replace `environment.sessionVariables` (lines 429–436) with:

```nix
  # Environment variables for games
  environment.sessionVariables.GAMES_DIR = "/mnt/games";
```

Drop `self`, `inputs` and `lib` from the argument list if they are no longer referenced. `grep -n 'self\|inputs\|lib\.' hosts/raider/configuration.nix` should print nothing.

- [ ] **Step 8: Check nothing was lost or duplicated**

```bash
git show $BASE:hosts/raider/configuration.nix | grep -v '^\s*$' | sort > /tmp/r.old
cat hosts/raider/{configuration,stash,niks3,backup,nix-builds,no-suspend}.nix | grep -v '^\s*$' | sort > /tmp/r.new
diff /tmp/r.old /tmp/r.new
```
Expected: only headers, `imports` lines, the `constellation.backrest`/`sessionVariables` rewrites, and indentation changes. No setting line may appear on the `<` side alone.

- [ ] **Step 9: Format, stage, commit**

```bash
just fmt
git add hosts/raider/
git status --short   # only hosts/raider/ staged
git commit -m "refactor(raider): split configuration.nix by concern"
```

- [ ] **Step 10: Verify the drvPath is identical**

```bash
drv raider $(git rev-parse HEAD) > /tmp/raider.after
diff /tmp/raider.before /tmp/raider.after && echo IDENTICAL
```
Expected: `IDENTICAL`. On a mismatch, run `nix-diff` as in Task 1 Step 11. Likely causes are a list whose order changed (dconf databases, `nixpkgs.overlays`, anything the niks3 upstream module adds) or the niks3 import being in the wrong slot. Fix it, `git commit --amend --no-edit` and repeat.

---

### Task 3: Final check and push

- [ ] **Step 1: Check both hosts again at the final revision**

```bash
HEAD=$(git rev-parse HEAD)
[ "$(drv blackbird $HEAD)" = "$(cat /tmp/blackbird.before)" ] && \
[ "$(drv raider $HEAD)" = "$(cat /tmp/raider.before)" ] && echo BOTH IDENTICAL
```
Expected: `BOTH IDENTICAL`.

- [ ] **Step 2: Push**

```bash
git push -u origin master
```

Nothing to deploy: identical drvPaths mean identical systems.
