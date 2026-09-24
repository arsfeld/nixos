# Workstation Dedup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove the options raider and blackbird each set for themselves, moving the real duplicates into `desktop.nix` and `gaming.nix`, with no change to what any host evaluates to.

**Architecture:** Three moves: delete restatements, move boot/keyboard/filesystem settings into `desktop.nix`, and move the BORE kernel plus the Chaotic-Nyx overlay into `gaming.nix`. Each move is checked the same way: a snapshot of the affected option values for every host is taken before any edit, and must match exactly after each task.

**Tech Stack:** NixOS modules, flake-parts, haumea (auto-loads `modules/`), Chaotic-Nyx.

Spec: `docs/superpowers/specs/2026-09-24-workstation-dedup-design.md`

## Global Constraints

- Pure refactor: every host's evaluated values for the options touched here must be identical before and after. A snapshot diff is a bug in the move, never something to accept.
- No new module, no new option.
- Leave per host: `networking.firewall.enable = false`, systemd-boot settings, logind settings, `permittedInsecurePackages`.
- Do not touch `sops.secrets."ntfy-publisher-env"` (out of scope).
- Commit straight to `master`. No branches or worktrees.
- Conventional commits: `<type>(<scope>): <subject>`. Never mention Claude.
- Do not stage `hosts/galactica/services/files.nix`. It is an unrelated uncommitted change. Always commit with an explicit path list.
- Run `just fmt` before every commit. CI fails on unformatted Nix.

## Files

- Modify `hosts/raider/configuration.nix`: delete restatements and moved options; keep `"nfs"`.
- Modify `hosts/blackbird/configuration.nix`: delete restatements and moved options.
- Modify `hosts/blackbird/hardware-configuration.nix`: one comment about where `nvidia_cachyos-bore` comes from.
- Modify `modules/constellation/desktop.nix`: shared base gains Plymouth, xkb, `supportedFilesystems`.
- Modify `modules/constellation/gaming.nix`: imports `nyx-overlay`, gates it, defaults the kernel to cachyos-bore.
- Scratch only, not committed: `$S/snapshot.nix`, `$S/check.sh`, `$S/baseline.json`, where
  `S=/tmp/claude-1000/-home-arosenfeld-Code-nixos/f1ed127c-7c52-49b4-9827-261a5a6a73b8/scratchpad/dedup`.

---

### Task 1: Baseline snapshot

The "test" for every later task: one JSON value per host, covering every option this plan touches, plus a few leak detectors (the overlay count and the Nyx switch).

**Files:**
- Create: `$S/snapshot.nix`, `$S/check.sh`, `$S/baseline.json`

**Interfaces:**
- Produces: `bash $S/check.sh` compares the current tree against `$S/baseline.json`. It exits 0 with `SNAPSHOT MATCH` or exits 1 and prints the diff. Tasks 2–5 run it.

- [ ] **Step 1: Write the snapshot expression**

`$S/snapshot.nix`:

```nix
# Called with the flake; returns { <host> = { ...values... }; } for every host.
flake: let
  pick = name: let
    c = flake.nixosConfigurations.${name}.config;
  in {
    kernel = c.boot.kernelPackages.kernel.drvPath;
    fs = c.boot.supportedFilesystems;
    plymouth = c.boot.plymouth.enable;
    plymouthTheme = c.boot.plymouth.theme;
    initrdVerbose = c.boot.initrd.verbose;
    consoleLogLevel = c.boot.consoleLogLevel;
    xkb = {inherit (c.services.xserver.xkb) layout variant;};
    keyMap = c.console.keyMap;
    openssh = c.services.openssh.enable;
    timeZone = c.time.timeZone;
    locale = c.i18n.defaultLocale;
    nftables = c.networking.nftables.enable;
    nmWaitOnline = c.systemd.services.NetworkManager-wait-online.enable or null;
    firewall = c.networking.firewall.enable;
    nyxOverlay = c.chaotic.nyx.overlay.enable or null;
    overlayCount = builtins.length c.nixpkgs.overlays;
    nvidia =
      if c.hardware.nvidia.enabled or false
      then c.hardware.nvidia.package.drvPath
      else null;
  };
in
  builtins.listToAttrs (map (n: {
    name = n;
    value = pick n;
  }) (builtins.attrNames flake.nixosConfigurations))
```

`nyxOverlay` is expected to change from `null` to a boolean on hosts that never imported the module. `check.sh` normalises that: `null` and `false` are treated as the same, because both mean the overlay is off. Every other field must match exactly.

- [ ] **Step 2: Write the check script**

`$S/check.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
S=/tmp/claude-1000/-home-arosenfeld-Code-nixos/f1ed127c-7c52-49b4-9827-261a5a6a73b8/scratchpad/dedup
cd /home/arosenfeld/Code/nixos
snap() {
  nix eval --json --impure --expr \
    "import $S/snapshot.nix (builtins.getFlake \"git+file://$PWD\")" 2>/dev/null |
    jq -S 'map_values(.nyxOverlay |= (. // false))'
}
if [ "${1:-}" = "--baseline" ]; then
  snap >"$S/baseline.json"
  echo "baseline written: $(jq 'keys | length' "$S/baseline.json") hosts"
  exit 0
fi
snap >"$S/current.json"
if diff -u "$S/baseline.json" "$S/current.json"; then
  echo "SNAPSHOT MATCH"
else
  echo "SNAPSHOT DIFFERS"
  exit 1
fi
```

`git+file://` makes the flake see uncommitted edits to tracked files. Every file this plan edits is already tracked.

- [ ] **Step 3: Record the baseline**

```bash
mkdir -p $S && chmod +x $S/check.sh && $S/check.sh --baseline
```

Expected: `baseline written: 10 hosts`. The count must equal `ls -d hosts/*/configuration.nix | wc -l`.

Sanity check that the baseline is meaningful:

```bash
jq '{raider: .raider.kernel, blackbird: .blackbird.kernel, galactica: .galactica.kernel}' $S/baseline.json
```

Expected: raider and blackbird kernel paths contain `cachyos-bore`; galactica's does not.

- [ ] **Step 4: Confirm the check passes on an untouched tree**

Run: `$S/check.sh`
Expected: `SNAPSHOT MATCH`. If it does not match, the snapshot is non-deterministic. Fix that before continuing.

- [ ] **Step 5: Record baseline toplevels for the final nix-diff**

```bash
for h in raider blackbird galactica; do
  nix eval --raw .#nixosConfigurations.$h.config.system.build.toplevel.drvPath > $S/toplevel-$h.before
done
```

No commit: nothing in the repo changed.

---

### Task 2: Delete restatements from both hosts

**Files:**
- Modify: `hosts/raider/configuration.nix`
- Modify: `hosts/blackbird/configuration.nix`

**Interfaces:**
- Consumes: `$S/check.sh` (Task 1).

These are already set at the same value by `modules/constellation/common.nix` (openssh, time zone, locale, nftables), `modules/constellation/desktop.nix` shared base (NetworkManager-wait-online), or the NixOS default (`console.keyMap = "us"`).

- [ ] **Step 1: raider: delete these lines, including their comments**

```nix
  systemd.services.NetworkManager-wait-online.enable = false;
```

```nix
  networking.nftables.enable = true;
```

```nix
  # Set your time zone
  time.timeZone = "America/Toronto";

  # Select internationalisation properties
  i18n.defaultLocale = "en_CA.UTF-8";
```

```nix
  # Configure console keymap
  console.keyMap = "us";

  # Enable the OpenSSH daemon
  services.openssh.enable = true;
```

Also delete the stale comment block that sits right after the nftables line and describes nothing:

```nix
  # Additional system services specific to this machine
  # CoolerControl is configured in ./coolercontrol.nix
```

- [ ] **Step 2: blackbird: delete these lines, including their comments**

```nix
  # Networking configuration
  networking.nftables.enable = true;
```

```nix
  # Disable wait-online service to speed up boot
  systemd.services.NetworkManager-wait-online.enable = false;
```

```nix
  # Set your time zone
  time.timeZone = "America/Toronto";

  # Select internationalisation properties
  i18n.defaultLocale = "en_CA.UTF-8";
```

```nix
  # Configure console keymap
  console.keyMap = "us";

  # Enable the OpenSSH daemon
  services.openssh.enable = true;
```

Leave both hosts' `services.xserver.xkb` block alone. It moves in Task 3.

- [ ] **Step 3: Verify**

Run: `just fmt && $S/check.sh`
Expected: `SNAPSHOT MATCH`.

- [ ] **Step 4: Commit**

```bash
git commit -m "refactor(raider,blackbird): drop options common and desktop already set" -- hosts/raider/configuration.nix hosts/blackbird/configuration.nix
```

---

### Task 3: Move boot appearance, keyboard and filesystems into desktop.nix

**Files:**
- Modify: `modules/constellation/desktop.nix` (shared base block, after `systemd.services.NetworkManager-wait-online.enable = false;` near line 136)
- Modify: `hosts/raider/configuration.nix`
- Modify: `hosts/blackbird/configuration.nix`

**Interfaces:**
- Consumes: `$S/check.sh` (Task 1).
- Produces: every `constellation.desktop.enable` host gets Plymouth `bgrt`, xkb `us`/`alt-intl`, and the extra filesystem list.

- [ ] **Step 1: Add to the desktop.nix shared base**

Insert directly after `systemd.services.NetworkManager-wait-online.enable = false;` in the `# ======== SHARED BASE (every variant) ========` block:

```nix

        # Quiet graphical boot: firmware logo (bgrt) through to the greeter.
        boot.plymouth = {
          enable = true;
          theme = "bgrt";
        };
        boot.initrd.verbose = false;
        boot.consoleLogLevel = 0;

        services.xserver.xkb = {
          layout = "us";
          variant = "alt-intl";
        };

        # Filesystems a desktop may meet on removable or network media. NixOS
        # derives only what fileSystems declares (btrfs, vfat, xfs here), so
        # these are additions, not a restriction. Nothing in this fleet
        # contributes zfs; the "remove zfs" mkForce this replaces was stale.
        # A plain definition, so hosts can append (raider adds nfs).
        boot.supportedFilesystems = ["btrfs" "cifs" "f2fs" "jfs" "ntfs" "reiserfs" "vfat" "xfs"];
```

- [ ] **Step 2: raider: delete the moved lines**

Delete:

```nix
  # Boot appearance
  boot.plymouth.enable = true;
  boot.plymouth.theme = "bgrt";
  boot.initrd.verbose = false;
  boot.consoleLogLevel = 0;
```

```nix
  # Configure keymap in X11
  services.xserver = {
    xkb.layout = "us";
    xkb.variant = "alt-intl";
  };
```

Replace:

```nix
  # Remove zfs, add nfs for media mount
  boot.supportedFilesystems = lib.mkForce ["btrfs" "cifs" "f2fs" "jfs" "nfs" "ntfs" "reiserfs" "vfat" "xfs"];
```

with:

```nix
  # nfs for the media mount; the rest come from constellation.desktop.
  boot.supportedFilesystems = ["nfs"];
```

- [ ] **Step 3: blackbird: delete the moved lines**

Delete:

```nix
  # Boot appearance
  boot.plymouth.enable = true;
  boot.plymouth.theme = "bgrt";
  boot.initrd.verbose = false;
  boot.consoleLogLevel = 0;
```

```nix
  # Remove zfs support
  boot.supportedFilesystems = lib.mkForce ["btrfs" "cifs" "f2fs" "jfs" "ntfs" "reiserfs" "vfat" "xfs"];
```

```nix
  # Configure keymap in X11
  services.xserver = {
    xkb.layout = "us";
    xkb.variant = "alt-intl";
  };
```

- [ ] **Step 4: Verify**

Run: `just fmt && $S/check.sh`
Expected: `SNAPSHOT MATCH`. `fs` is an attrset of booleans, so list order cannot cause a false diff.

- [ ] **Step 5: Commit**

```bash
git commit -m "refactor(modules): desktop owns boot splash, keyboard and filesystems" -- modules/constellation/desktop.nix hosts/raider/configuration.nix hosts/blackbird/configuration.nix
```

---

### Task 4: Move the BORE kernel and Nyx overlay into gaming.nix

**Files:**
- Modify: `modules/constellation/gaming.nix` (argument list at the top; `in {` at line 29; kernel line at ~134)
- Modify: `hosts/raider/configuration.nix`
- Modify: `hosts/blackbird/configuration.nix`
- Modify: `hosts/blackbird/hardware-configuration.nix` (~line 88)

**Interfaces:**
- Consumes: `$S/check.sh` (Task 1). `inputs` reaches modules through `specialArgs` (`flake-modules/lib.nix:95`), so it is usable in `imports`.
- Produces: `chaotic.nyx.overlay.enable` is `false` on every host except gaming hosts; gaming hosts default to `linuxPackages_cachyos-bore` at `mkOverride 990`.

- [ ] **Step 1: Add `inputs` to gaming.nix arguments**

```nix
{
  config,
  options,
  pkgs,
  lib,
  inputs,
  ...
}: let
```

- [ ] **Step 2: Import the overlay module and gate it**

Change `in {` (line 29) to:

```nix
in {
  # Chaotic-Nyx: source of the CachyOS BORE kernel below (and of
  # nvidia_cachyos-bore, which blackbird's hardware config uses). modules/ is
  # loaded into every host, and the overlay's own enable defaults to true, so
  # it is switched off here and back on only for gaming hosts. nyx-cache is in
  # common.nix; nyx-registry is deliberately not imported (common.nix already
  # registers every flake input).
  imports = [inputs.chaotic.nixosModules.nyx-overlay];

```

In the `config = lib.mkMerge [` list, add this as the **first** element, before `(lib.mkIf config.constellation.gaming.enable {`:

```nix
    {chaotic.nyx.overlay.enable = lib.mkDefault config.constellation.gaming.enable;}
```

This one line covers both cases (off everywhere, on for gaming), and `mkDefault` still beats the upstream option default.

- [ ] **Step 3: Replace the xanmod default**

Replace:

```nix
      # Gaming kernel optimizations
      boot = lib.mkIf config.constellation.gaming.kernelOptimizations {
        kernelPackages = lib.mkOverride 990 pkgs.linuxPackages_xanmod_latest;
```

with:

```nix
      # Gaming kernel optimizations
      boot = lib.mkIf config.constellation.gaming.kernelOptimizations {
        # BORE scheduler, from Chaotic-Nyx's CachyOS kernel. XanMod carries no
        # CONFIG_SCHED_BORE at all (only sched_ext), so BORE has to come from
        # here, and specifically from the `cachyos-bore` variant: the default
        # `linuxPackages_cachyos` (cachyos-lto) is EEVDF. BORE is compiled on
        # and enabled by default; verify after deploy with
        # `cat /proc/sys/kernel/sched_bore`.
        kernelPackages = lib.mkOverride 990 pkgs.linuxPackages_cachyos-bore;
```

- [ ] **Step 4: raider: delete the import and the kernel override**

From `imports`, delete:

```nix
    # Chaotic-Nyx: source of the BORE-scheduler CachyOS kernel below.
    # nyx-cache is in common.nix; nyx-registry is deliberately NOT imported
    # (common.nix already registers every flake input).
    inputs.chaotic.nixosModules.nyx-overlay
```

Delete the whole block:

```nix
  # BORE scheduler. `constellation.gaming` pins every gaming host to
  ...
  boot.kernelPackages = lib.mkForce pkgs.linuxPackages_cachyos-bore;
```

(the 9 comment lines starting `# BORE scheduler.` through the `boot.kernelPackages` line).

- [ ] **Step 5: blackbird: delete the import and the kernel override**

From `imports`, delete `inputs.chaotic.nixosModules.nyx-overlay`. Delete:

```nix
  # CachyOS BORE kernel from Chaotic-Nyx, mirroring raider.
  boot.kernelPackages = lib.mkForce pkgs.linuxPackages_cachyos-bore;
```

If `inputs` is now unused in blackbird's argument list, leave it: `...` absorbs it, and the other hosts keep theirs.

- [ ] **Step 6: blackbird hardware config: record the dependency**

In `hosts/blackbird/hardware-configuration.nix`, directly above `package = pkgs.nvidia_cachyos-bore;` add:

```nix
    # Exists only via Chaotic-Nyx's overlay, which constellation.gaming enables.
```

- [ ] **Step 7: Verify**

Run: `just fmt && $S/check.sh`
Expected: `SNAPSHOT MATCH`. Pay particular attention to these fields, where this task could go wrong:
- `raider.kernel`/`blackbird.kernel`: unchanged, meaning cachyos-bore reached through the module.
- `blackbird.nvidia`: unchanged.
- `galactica.overlayCount` and every non-gaming host's `overlayCount`: unchanged, meaning the overlay did not leak.
- `nyxOverlay`: `false` for non-gaming hosts, `true` for raider and blackbird. The baseline normalised `null` → `false`, and raider/blackbird were already `true`.

- [ ] **Step 8: Commit**

```bash
git commit -m "refactor(modules): gaming owns the CachyOS BORE kernel and Nyx overlay" -- modules/constellation/gaming.nix hosts/raider/configuration.nix hosts/blackbird/configuration.nix hosts/blackbird/hardware-configuration.nix
```

---

### Task 5: Whole-system verification

**Files:** none modified.

**Interfaces:**
- Consumes: `$S/toplevel-*.before` (Task 1 Step 5).

- [ ] **Step 1: nix-diff the full systems**

```bash
for h in raider blackbird galactica; do
  after=$(nix eval --raw .#nixosConfigurations.$h.config.system.build.toplevel.drvPath)
  echo "== $h"; nix run nixpkgs#nix-diff -- --color never "$(cat $S/toplevel-$h.before)" "$after" | grep -vE '^\s*$' | head -80
done
```

Expected: the only differences trace back to the flake source (`…-source` store paths, `configurationRevision`/version strings, and derivations that embed them, such as sops manifests and `/etc` entries referencing `${self}`). There must be **no** difference in kernel, initrd content, plymouth, xkb, systemd units other than those carrying the source path, or package set. Anything else is a bug in Tasks 2–4. Fix it; do not accept it.

- [ ] **Step 2: Flake checks**

Run: `nix flake check`
Expected: passes.

- [ ] **Step 3: Confirm the tree is clean apart from the unrelated file**

Run: `git status --short`
Expected: only ` M hosts/galactica/services/files.nix`.

No deploy is needed. The result is identical, so the next routine deploy carries it.
