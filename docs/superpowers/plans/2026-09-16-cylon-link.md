# cylon-link Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Run NixOS on a Valve Steam Link as the fleet host `cylon-link`, deployable with `just deploy cylon-link` like any other host.

**Architecture:** Valve's stock firmware runs `run.sh` from partition 1 of a USB stick. `run.sh` picks a staged NixOS generation and `kexec`s into nixpkgs' 6.18 kernel, which boots NixOS from partition 2. A NixOS install hook stages generations onto partition 1. A boot-confirmation unit marks a generation good once Tailscale is up. Attempt markers make a failed generation fall back to the last good one, and then to the stock firmware as a rescue shell. The host is cross-compiled from x86_64 on raider and kept out of CI.

**Tech Stack:** NixOS (nixpkgs 26.05 pin), `boot.loader.external`, `pkgsStatic.kexec-tools`, POSIX sh / bash, sops-nix, just.

**Spec:** `docs/superpowers/specs/2026-09-16-cylon-link-design.md`

## Global Constraints

- Commit straight to `master`. No branches, no worktrees, even if a sub-skill suggests one.
- Commit messages: `<type>(<scope>): <subject>`, with scope `cylon-link`, `modules` or `secrets`. Never mention Claude.
- A new file is invisible to `nix build`/`nix eval` until it is tracked. Run `git add -N <path>` right after creating it.
- Run `just fmt` (alejandra) before every commit that touches `.nix` files.
- Never edit sops files interactively. Use `sops --encrypt --filename-override …` and `sops updatekeys -y …`, inside `nix develop`.
- Builds that take more than a few minutes on raider must run as a `systemd-run --user` unit. Claude Code's background-task monitor has killed long builds there while earlyoom reported 84% of memory available.
- Hostname: `cylon-link`. Partition labels: `CYLON_BOOT` (p1, ext3) and `CYLON_ROOT` (p2, ext4). p1 mount point on NixOS: `/boot/steamlink`.
- Device tree: `berlin2cd-valve-steamlink.dtb`. Kernel command line additions: `console=ttyS0,115200n8 usbcore.autosuspend=-1`.
- `kexec_load.ko`: `https://raw.githubusercontent.com/djmuted/steamlink-debian/216b58b6e9bb4ba20a9648d1ef089d7b6dbb58df/rootfs/boot/kexec_load.ko`, hash `sha256-sbinlkoG1+vNRRcLZWX22eNIxfyIXro65/yBj0BLGVY=`.
- `run.sh` must be POSIX `sh`. Its only external commands are `sync`, `insmod` and `fts-set`, and it contains no `/nix/store` paths. It runs under Valve's Linux 3.8.13, where nixpkgs' glibc (`--enable-kernel=3.10.0`) cannot run.
- The stick is `/dev/disk/by-id/usb-Kingston_DataTraveler_3.0_1C6F654E4168F290E9213192-0:0`. Erasing it needs the user's confirmation in the session that runs Task 7.
- Tier-1 hosts must not change. After Task 2, galactica's package list is identical to before.
- This nixpkgs defaults to the systemd initrd (`boot.initrd.systemd.enable = true`). Scripted-initrd options such as `boot.initrd.postDeviceCommands` fail evaluation. Use `boot.initrd.systemd.*` or kernel parameters instead.

## File Structure

| Path | Responsibility |
|---|---|
| `hosts/cylon-link/boot/run.sh` | Firmware-side boot selector (data copied to p1) |
| `hosts/cylon-link/boot/cylon-link-boot.sh` | `install` and `confirm` subcommands: p1 staging and the marker protocol |
| `hosts/cylon-link/boot/package.nix` | Builds `cylon-link-boot` for any platform, with the boot payload baked in |
| `hosts/cylon-link/boot/test.nix` | Flake check: scripts and `run.sh` under busybox, with stubbed firmware commands |
| `hosts/cylon-link/boot/default.nix` | NixOS module: p1 mount, install hook, `cylon-link-boot-ok.service`, `system.build.cylonLinkBoot` |
| `hosts/cylon-link/hardware.nix` | Platform, kernel, device tree, root filesystem, networking |
| `hosts/cylon-link/configuration.nix` | Identity and fleet toggles |
| `hosts/cylon-link/config-test.nix` | Flake check: design invariants plus required kernel config options |
| `hosts/cylon-link/flash.sh` | Root-side stick writer (partition, format, copy closure, stage p1) |
| `flake-modules/checks.nix` | Wires the two checks (x86_64-linux only) |
| `flake-modules/lib.nix` | `lightHosts` gains `cylon-link` |
| `flake-modules/hosts.nix` | `ciExcludedHosts`, filtered out of `ciMatrix` |
| `modules/constellation/common.nix` | `constellation.common.minimal` |
| `.sops.yaml`, `secrets/sops/cylon-link-hostkey.yaml`, `secrets/sops/common.yaml` | Host key and sops recipient |
| `justfile` | `flash-cylon-link DEVICE` |
| `CLAUDE.md`, `HARDWARE.md`, the spec | Docs |

---

### Task 1: Boot-chain scripts and their flake check

**Files:**
- Create: `hosts/cylon-link/boot/test.nix`
- Create: `hosts/cylon-link/boot/run.sh`
- Create: `hosts/cylon-link/boot/cylon-link-boot.sh`
- Create: `hosts/cylon-link/boot/package.nix`
- Modify: `flake-modules/checks.nix`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `hosts/cylon-link/boot/package.nix` is a `callPackage`-able function with arguments `{writeShellApplication, coreutils, kexec, kexecModule, dtbName ? "berlin2cd-valve-steamlink.dtb"}`.
    - `kexec` and `kexecModule` are strings with store context.
    - It returns a derivation whose main program is `bin/cylon-link-boot`.
  - The CLI has two subcommands:
    - `cylon-link-boot install TOPLEVEL P1` stages TOPLEVEL as `P1/nixos/new`. It removes `P1/nixos/tried-new`, and installs `P1/steamlink/factory_test/run.sh`, `P1/steamlink/bin/kexec` and `P1/steamlink/kexec_load.ko`.
    - `cylon-link-boot confirm P1 CMDLINE_FILE` applies the confirmation rules from the spec.
  - `P1/nixos/<entry>/` contains `zImage`, `initrd`, `dtb` and `cmdline`. `cmdline` is one line: `<contents of TOPLEVEL/kernel-params> init=TOPLEVEL/init`.
  - Markers: `P1/nixos/tried-new`, `P1/nixos/tried-good`, `P1/steamlink/rescue`.
  - Check attribute: `checks.x86_64-linux.cylon-link-boot`.

- [ ] **Step 1: Write the failing check**

Create `hosts/cylon-link/boot/test.nix`:

```nix
# Exercises cylon-link's boot chain on the build platform: cylon-link-boot's
# install and confirm subcommands, and run.sh under busybox sh with Valve's
# firmware commands and kexec replaced by stubs that log their arguments.
{pkgs}: let
  sh = "${pkgs.busybox}/bin/sh";

  stubs = pkgs.runCommand "cylon-link-boot-stubs" {} ''
    mkdir -p $out/bin
    for cmd in insmod fts-set; do
      printf '#!${sh}\necho "%s $*" >>"$LOG"\n' "$cmd" >$out/bin/$cmd
    done
    cat >$out/bin/kexec <<'EOF'
    #!${sh}
    echo "kexec $*" >>"$LOG"
    [ "$1" = -e ] && exit 0
    [ -z "''${KEXEC_FAIL:-}" ]
    EOF
    chmod +x $out/bin/*
  '';

  bootTool = pkgs.callPackage ./package.nix {
    kexec = "${stubs}/bin/kexec";
    kexecModule = "${pkgs.writeText "kexec_load.ko" "stub module"}";
  };

  # Just enough of a NixOS toplevel for the installer.
  mkToplevel = name:
    pkgs.runCommand "fake-toplevel-${name}" {} ''
      mkdir -p $out/dtbs
      echo "zImage ${name}" >$out/kernel
      echo "initrd ${name}" >$out/initrd
      echo "dtb ${name}" >$out/dtbs/berlin2cd-valve-steamlink.dtb
      printf 'root=fstab loglevel=4' >$out/kernel-params
      touch $out/init
    '';
  top1 = mkToplevel "top1";
  top2 = mkToplevel "top2";
in
  pkgs.runCommand "cylon-link-boot-test" {} ''
    set -euo pipefail
    export LOG=$PWD/calls.log
    export PATH=${stubs}/bin:$PATH
    p1=$PWD/p1
    boot=${bootTool}/bin/cylon-link-boot

    fail() { echo "FAIL: $*" >&2; echo "--- calls:" >&2; cat "$LOG" >&2 || true; exit 1; }
    # The firmware runs run.sh by absolute path, from its own cwd.
    run_sh() { : >"$LOG"; (cd / && ${sh} "$p1/steamlink/factory_test/run.sh"); }
    booted() {
      grep -q -- "-l $p1/nixos/$1/zImage --initrd $p1/nixos/$1/initrd --dtb $p1/nixos/$1/dtb" "$LOG" &&
        grep -q "cylon.entry=$1" "$LOG" && grep -q -- "^kexec -e" "$LOG"
    }
    no_kexec() { ! grep -q '^kexec' "$LOG"; }
    staged() { grep -q "zImage $2" "$p1/nixos/$1/zImage"; }
    confirm() { printf '%s\n' "$1" >cmdline; $boot confirm "$p1" cmdline; }

    echo "== install stages a fresh stick"
    $boot install ${top1} "$p1"
    [ -x "$p1/steamlink/factory_test/run.sh" ] || fail "run.sh not installed"
    cmp -s "$p1/steamlink/factory_test/run.sh" ${./run.sh} || fail "run.sh differs from the repo copy"
    [ -x "$p1/steamlink/bin/kexec" ] || fail "kexec not installed"
    [ -f "$p1/steamlink/kexec_load.ko" ] || fail "kexec_load.ko not installed"
    staged new top1 || fail "kernel not staged"
    grep -q "initrd top1" "$p1/nixos/new/initrd" || fail "initrd not staged"
    grep -q "dtb top1" "$p1/nixos/new/dtb" || fail "dtb not staged"
    [ "$(cat "$p1/nixos/new/cmdline")" = "root=fstab loglevel=4 init=${top1}/init" ] ||
      fail "cmdline is: $(cat "$p1/nixos/new/cmdline")"
    [ ! -e "$p1/nixos/good" ] || fail "a fresh stick must have no good entry"

    echo "== first power-on boots new"
    run_sh || fail "run.sh failed"
    booted new || fail "did not boot new"
    grep -q "^fts-set steamlink.crashcounter 0" "$LOG" || fail "crash counter not reset"
    grep -q "^insmod $p1/steamlink/kexec_load.ko" "$LOG" || fail "kexec module not loaded"
    [ -e "$p1/nixos/tried-new" ] || fail "tried-new not recorded"

    echo "== a failed first boot leaves the stock firmware running"
    run_sh || fail "run.sh failed"
    no_kexec || fail "kexec called with nothing left to try"

    echo "== confirming new makes it good"
    confirm "root=fstab loglevel=4 init=${top1}/init cylon.entry=new"
    staged good top1 || fail "good not copied from new"
    [ ! -e "$p1/nixos/tried-new" ] || fail "tried-new not cleared"

    echo "== installing a newer generation re-arms new and keeps good"
    $boot install ${top2} "$p1"
    staged new top2 || fail "new not replaced"
    staged good top1 || fail "good changed on install"
    [ ! -e "$p1/nixos/tried-new" ] || fail "install left tried-new"

    echo "== a failed new falls back to good, then to the firmware"
    run_sh || fail "run.sh failed"
    booted new || fail "did not try new"
    run_sh || fail "run.sh failed"
    booted good || fail "did not fall back to good"
    [ -e "$p1/nixos/tried-good" ] || fail "tried-good not recorded"
    run_sh || fail "run.sh failed"
    no_kexec || fail "kexec called after both entries failed"

    echo "== confirming good clears only tried-good"
    confirm "root=fstab loglevel=4 init=${top1}/init cylon.entry=good"
    [ ! -e "$p1/nixos/tried-good" ] || fail "tried-good not cleared"
    [ -e "$p1/nixos/tried-new" ] || fail "tried-new must stay after booting good"
    run_sh || fail "run.sh failed"
    booted good || fail "should keep booting good"

    echo "== confirming a replaced new leaves good alone"
    confirm "root=fstab loglevel=4 init=${top1}/init cylon.entry=new"
    staged good top1 || fail "good must not change"
    staged new top2 || fail "new must not change"
    [ ! -e "$p1/nixos/tried-good" ] || fail "tried-good not cleared"

    echo "== confirm refuses a command line without cylon.entry"
    if confirm "root=fstab init=${top1}/init"; then fail "confirm accepted a missing entry"; fi

    echo "== the rescue switch keeps the firmware running"
    rm -f "$p1/nixos/tried-new" "$p1/nixos/tried-good"
    touch "$p1/steamlink/rescue"
    run_sh || fail "run.sh failed"
    no_kexec || fail "kexec called in rescue mode"
    rm "$p1/steamlink/rescue"

    echo "== a failed kexec load returns to the firmware"
    if (export KEXEC_FAIL=1; run_sh); then fail "run.sh succeeded although kexec -l failed"; fi
    ! grep -q -- "^kexec -e" "$LOG" || fail "kexec -e ran after a failed load"

    echo "== run.sh also works when started by relative path"
    rm -f "$p1/nixos/tried-new"
    : >"$LOG"
    (cd "$p1/steamlink/factory_test" && ${sh} ./run.sh) || fail "run.sh failed"
    booted new || fail "relative invocation did not boot new"

    touch $out
  ''
```

Modify `flake-modules/checks.nix`. Replace the whole `checks = { … };` attribute so the existing checks stay as they are and the new one is appended for x86_64-linux only:

```nix
  perSystem = {system, ...}: {
    checks =
      {
        # … existing router-test, router-test-production, harmonia-cache-test,
        # blackbird-audio-control-test and immich-pixel-sync-test, unchanged …
      }
      // inputs.nixpkgs.lib.optionalAttrs (system == "x86_64-linux") {
        # cylon-link is cross-compiled from x86_64; its checks are too.
        cylon-link-boot = import ../hosts/cylon-link/boot/test.nix {
          pkgs = inputs.nixpkgs.legacyPackages.${system};
        };
      };
  };
```

(Keep the five existing entries verbatim inside the first attribute set. Only the `// … optionalAttrs` part is new.)

- [ ] **Step 2: Track the new file and run the check to see it fail**

```bash
git add -N hosts/cylon-link/boot/test.nix
nix build .#checks.x86_64-linux.cylon-link-boot -L
```

Expected: an evaluation error saying `hosts/cylon-link/boot/package.nix` does not exist.

- [ ] **Step 3: Write `run.sh`**

Create `hosts/cylon-link/boot/run.sh`:

```sh
#!/bin/sh
# cylon-link boot selector.
#
# Valve's stock firmware (Linux 3.8.13) runs this at every power-on, as
# steamlink/factory_test/run.sh on the stick's first partition (CYLON_BOOT).
# It picks a NixOS generation staged there and kexecs into it.
#
# Constraints, all load-bearing:
# - POSIX sh, and no external commands except sync, insmod and fts-set, which
#   the firmware has. NixOS binaries cannot run under this kernel: nixpkgs'
#   glibc requires Linux >= 3.10. The kexec called below is static musl.
# - No /nix/store paths. The firmware never mounts CYLON_ROOT.
#
# Protocol, shared with cylon-link-boot (install and confirm):
#   nixos/new          last installed generation
#   nixos/good         last generation that booted and reached Tailscale
#   nixos/tried-new    new was attempted and not yet confirmed
#   nixos/tried-good   good was attempted and not yet confirmed
#   steamlink/rescue   if present, do nothing
# Each entry is tried once until something clears its marker. When nothing is
# left to try, this exits and the firmware keeps booting, SSH included: that
# is the rescue shell.

case $0 in
*/*) here=${0%/*} ;;
*) here=. ;;
esac
p1=$(cd "$here/../.." 2>/dev/null && pwd)
[ -n "$p1" ] && [ -d "$p1/nixos" ] || p1=/mnt/disk

fts-set steamlink.crashcounter 0

[ -e "$p1/steamlink/rescue" ] && exit 0

if [ -d "$p1/nixos/new" ] && [ ! -e "$p1/nixos/tried-new" ]; then
  entry=new
elif [ -d "$p1/nixos/good" ] && [ ! -e "$p1/nixos/tried-good" ]; then
  entry=good
else
  exit 0
fi

: >"$p1/nixos/tried-$entry"
sync

dir=$p1/nixos/$entry
read -r cmdline <"$dir/cmdline"
insmod "$p1/steamlink/kexec_load.ko" || :
"$p1/steamlink/bin/kexec" -c -l "$dir/zImage" --initrd "$dir/initrd" \
  --dtb "$dir/dtb" --command-line "$cmdline cylon.entry=$entry" || exit 1
sync
exec "$p1/steamlink/bin/kexec" -e
```

- [ ] **Step 4: Write `cylon-link-boot.sh`**

Create `hosts/cylon-link/boot/cylon-link-boot.sh` (no shebang; `writeShellApplication` adds one, with `errexit`, `nounset` and `pipefail`):

```bash
# cylon-link-boot: the NixOS side of cylon-link's boot chain. See run.sh for
# the protocol on the CYLON_BOOT partition.
#
#   cylon-link-boot install TOPLEVEL P1
#     Stage TOPLEVEL as the `new` entry and refresh the firmware payload.
#     NixOS runs this as boot.loader.external's hook on every switch/boot;
#     `just flash-cylon-link` runs a build-platform copy.
#   cylon-link-boot confirm P1 CMDLINE_FILE
#     Record the running entry as good. Run once per boot with /proc/cmdline.
#
# RUN_SH, KEXEC, KEXEC_MODULE and DTB_NAME come from package.nix.

usage() {
  echo "usage: cylon-link-boot install TOPLEVEL P1 | confirm P1 CMDLINE_FILE" >&2
  exit 2
}

# replace_dir STAGED DEST: move the staged directory over DEST.
replace_dir() {
  rm -rf "$2.old"
  if [[ -e $2 ]]; then mv "$2" "$2.old"; fi
  mv "$1" "$2"
  rm -rf "$2.old"
}

# install_file SRC DEST MODE: copy under a temporary name, then rename.
install_file() {
  cp "$1" "$2.tmp"
  chmod "$3" "$2.tmp"
  mv "$2.tmp" "$2"
}

cmd_install() {
  local toplevel=$1 p1=$2
  local staged=$p1/nixos/new.tmp
  mkdir -p "$p1/nixos" "$p1/steamlink/factory_test" "$p1/steamlink/bin"

  rm -rf "$staged"
  mkdir "$staged"
  cp "$toplevel/kernel" "$staged/zImage"
  cp "$toplevel/initrd" "$staged/initrd"
  cp "$toplevel/dtbs/$DTB_NAME" "$staged/dtb"
  printf '%s init=%s\n' "$(cat "$toplevel/kernel-params")" "$toplevel/init" >"$staged/cmdline"
  sync
  replace_dir "$staged" "$p1/nixos/new"
  rm -f "$p1/nixos/tried-new"

  install_file "$KEXEC_MODULE" "$p1/steamlink/kexec_load.ko" 0644
  install_file "$KEXEC" "$p1/steamlink/bin/kexec" 0755
  install_file "$RUN_SH" "$p1/steamlink/factory_test/run.sh" 0755
  sync
  echo "cylon-link: staged $toplevel for the next power-on"
}

# param NAME WORD...: print the value of NAME=... among WORDs.
param() {
  local name=$1 word
  shift
  for word in "$@"; do
    if [[ $word == "$name="* ]]; then
      printf '%s\n' "${word#*=}"
      return 0
    fi
  done
  return 1
}

cmd_confirm() {
  local p1=$1 entry running_init staged_init=""
  local -a words staged_words
  read -r -a words <"$2"
  entry=$(param cylon.entry "${words[@]}" || true)
  running_init=$(param init "${words[@]}" || true)

  case $entry in
  new)
    if [[ -r $p1/nixos/new/cmdline ]]; then
      read -r -a staged_words <"$p1/nixos/new/cmdline"
      staged_init=$(param init "${staged_words[@]}" || true)
    fi
    if [[ -n $running_init && $staged_init == "$running_init" ]]; then
      rm -rf "$p1/nixos/good.tmp"
      cp -a "$p1/nixos/new" "$p1/nixos/good.tmp"
      sync
      replace_dir "$p1/nixos/good.tmp" "$p1/nixos/good"
      rm -f "$p1/nixos/tried-new" "$p1/nixos/tried-good"
      echo "cylon-link: $running_init is now the good entry"
    else
      # A switch replaced `new` after this boot; it gets its own try.
      rm -f "$p1/nixos/tried-good"
      echo "cylon-link: booted an entry that has since been replaced; not recording it"
    fi
    ;;
  good)
    rm -f "$p1/nixos/tried-good"
    echo "cylon-link: running the good entry; the failed new entry stays marked as tried"
    ;;
  *)
    echo "cylon-link: no cylon.entry on the kernel command line, nothing to confirm" >&2
    return 1
    ;;
  esac
  sync
}

case ${1:-} in
install)
  [[ $# -eq 3 ]] || usage
  cmd_install "$2" "$3"
  ;;
confirm)
  [[ $# -eq 3 ]] || usage
  cmd_confirm "$2" "$3"
  ;;
*) usage ;;
esac
```

- [ ] **Step 5: Write `package.nix`**

Create `hosts/cylon-link/boot/package.nix`:

```nix
# cylon-link-boot, built from here twice: for the Steam Link (install hook and
# boot confirmation) and for the build platform (`just flash-cylon-link`, the
# flake check). run.sh travels as data: it runs under Valve's firmware.
{
  writeShellApplication,
  coreutils,
  # Static armv7l kexec, as a string with store context.
  kexec,
  # kexec_load.ko for Valve's 3.8.13 kernel, as a string with store context.
  kexecModule,
  dtbName ? "berlin2cd-valve-steamlink.dtb",
}:
writeShellApplication {
  name = "cylon-link-boot";
  runtimeInputs = [coreutils];
  # Interpolated, not bare paths: toShellVar would render a path without
  # copying it into the store, and the device would never receive run.sh.
  runtimeEnv = {
    RUN_SH = "${./run.sh}";
    KEXEC = kexec;
    KEXEC_MODULE = kexecModule;
    DTB_NAME = dtbName;
  };
  text = builtins.readFile ./cylon-link-boot.sh;
}
```

- [ ] **Step 6: Track the files and run the check**

```bash
git add -N hosts/cylon-link/boot/run.sh hosts/cylon-link/boot/cylon-link-boot.sh hosts/cylon-link/boot/package.nix
nix build .#checks.x86_64-linux.cylon-link-boot -L
```

Expected: it builds, and the log shows every `== …` heading with no `FAIL:`. If shellcheck (run by `writeShellApplication`) reports a finding, fix the script rather than excluding the check.

- [ ] **Step 7: Format and commit**

```bash
just fmt
git add hosts/cylon-link/boot flake-modules/checks.nix
git commit -m "feat(cylon-link): add kexec boot chain scripts and check"
```

---

### Task 2: `constellation.common.minimal`

**Files:**
- Modify: `modules/constellation/common.nix:28-37` (options), `:144-218` (systemPackages), `:220` (nix-ld)

**Interfaces:**
- Consumes: nothing.
- Produces: the option `constellation.common.minimal` (bool, default `false`). When `true`, `environment.systemPackages` from this module is the short list below and `programs.nix-ld.enable = false`.

- [ ] **Step 1: Record the current package lists (the regression baseline)**

```bash
S=/tmp/claude-1000/-home-arosenfeld-Code-nixos/cylon-link; mkdir -p $S
for h in galactica raspi3; do
  nix eval --json ".#nixosConfigurations.$h.config.environment.systemPackages" \
    --apply 'map (p: p.name or "?")' >"$S/$h-packages-before.json"
done
```

- [ ] **Step 2: Write the failing test**

```bash
nix eval --impure --json --expr '
  let
    f = builtins.getFlake (toString ./.);
    c = (f.nixosConfigurations.raspi3.extendModules {
      modules = [{constellation.common.minimal = true;}];
    }).config;
    pkgs = c.environment.systemPackages;
    names = map (p: p.name or "?") pkgs;
  in {
    nixLd = c.programs.nix-ld.enable;
    ffmpeg = builtins.any (n: builtins.match "ffmpeg.*" n != null) names;
    # A multi-output package keeps the base name (ghostty-1.3.1); only
    # outputName tells the terminfo output apart.
    terminfo = builtins.any (p: (p.pname or "") == "ghostty" && (p.outputName or "") == "terminfo") pkgs;
  }'
```

Expected: FAIL with `The option 'constellation.common.minimal' does not exist`.

- [ ] **Step 3: Implement**

In `modules/constellation/common.nix`, add after the `enable` option (inside `options.constellation.common`):

```nix
    minimal = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Keep the baseline small, for hosts with little RAM or no binary cache
        (cylon-link is cross-compiled for armv7l). Replaces the large tool
        list with a few basics and skips nix-ld. Caches, SSH, Tailscale, GC
        and the rest of the baseline are unchanged.
      '';
    };
```

Replace `environment.systemPackages = with pkgs; [` … `];` (lines 144–218) with the following. The `else` branch is the existing list, verbatim:

```nix
    environment.systemPackages =
      if config.constellation.common.minimal
      then
        with pkgs; [
          # Terminfo only: 5 KiB of data with no references, taken from the
          # build platform so a cross-compiled host never builds ghostty.
          buildPackages.ghostty.terminfo
          file
          htop
          iproute2
          lsof
          psmisc
          tcpdump
          tmux
          usbutils
          vim
        ]
      else
        with pkgs; [
          # … the existing list from "# From base profile" through zpaq, unchanged …
        ];
```

Replace `programs.nix-ld.enable = true;` with:

```nix
    programs.nix-ld.enable = !config.constellation.common.minimal;
```

- [ ] **Step 4: Run the test again**

Run the command from Step 2.
Expected: `{"ffmpeg":false,"nixLd":false,"terminfo":true}`

- [ ] **Step 5: Check that existing hosts are unchanged**

```bash
for h in galactica raspi3; do
  nix eval --json ".#nixosConfigurations.$h.config.environment.systemPackages" \
    --apply 'map (p: p.name or "?")' | cmp - "$S/$h-packages-before.json" && echo "$h unchanged"
done
```

Expected: `galactica unchanged` and `raspi3 unchanged`.

- [ ] **Step 6: Format and commit**

```bash
just fmt
git add modules/constellation/common.nix
git commit -m "feat(modules): add constellation.common.minimal"
```

---

### Task 3: Host key and sops recipient

**Files:**
- Create: `secrets/sops/cylon-link-hostkey.yaml` (encrypted to the user key only)
- Modify: `.sops.yaml` (key anchor, new rule, `common.yaml` rule)
- Modify: `secrets/sops/common.yaml` (re-encrypted, 11 recipients)

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `secrets/sops/cylon-link-hostkey.yaml` with keys `ssh_host_ed25519_key` (OpenSSH private key, block scalar with trailing newline) and `ssh_host_ed25519_key_pub`.
  - The `.sops.yaml` anchor `host_cylon_link`.

All commands run inside `nix develop`.

- [ ] **Step 1: Generate the key on tmpfs**

```bash
kd=$(mktemp -d "$XDG_RUNTIME_DIR/cylon-link-key.XXXXXX")
ssh-keygen -q -t ed25519 -N '' -C root@cylon-link -f "$kd/ssh_host_ed25519_key"
ssh-to-age <"$kd/ssh_host_ed25519_key.pub"
```

Expected: one `age1…` line. Call it `AGE_KEY` below.

- [ ] **Step 2: Write the failing test**

```bash
SOPS_AGE_KEY=$(ssh-to-age -private-key -i "$kd/ssh_host_ed25519_key") \
  sops --decrypt --extract '["tailscale-key"]' secrets/sops/common.yaml >/dev/null && echo "host can decrypt"
```

Expected: FAIL. sops reports it could not decrypt the data key with any available key.

- [ ] **Step 3: Edit `.sops.yaml`**

Add after the `&host_octopi` line:

```yaml
  - &host_cylon_link AGE_KEY
```

Add this rule after the `infra.yaml` rule:

```yaml
  # cylon-link's SSH host key, kept so a reflash (`just flash-cylon-link`)
  # preserves the host's sops identity. Only the flash recipe reads it, from
  # a workstation, so no host key is a recipient.
  - path_regex: secrets/sops/cylon-link-hostkey\.yaml$
    key_groups:
      - age:
          - *user_arosenfeld
```

In the `common.yaml` rule, add after `- *host_octopi`:

```yaml
          - *host_cylon_link
```

- [ ] **Step 4: Create the encrypted secret without writing plaintext into the repo**

```bash
{
  echo "ssh_host_ed25519_key: |"
  sed 's/^/  /' "$kd/ssh_host_ed25519_key"
  echo "ssh_host_ed25519_key_pub: $(cat "$kd/ssh_host_ed25519_key.pub")"
} >"$kd/plain.yaml"
sops --encrypt --input-type yaml --output-type yaml \
  --filename-override secrets/sops/cylon-link-hostkey.yaml \
  "$kd/plain.yaml" >secrets/sops/cylon-link-hostkey.yaml
sops updatekeys -y secrets/sops/common.yaml
```

- [ ] **Step 5: Verify**

```bash
SOPS_AGE_KEY=$(ssh-to-age -private-key -i "$kd/ssh_host_ed25519_key") \
  sops --decrypt --extract '["tailscale-key"]' secrets/sops/common.yaml >/dev/null && echo "host can decrypt"
sops --decrypt --extract '["ssh_host_ed25519_key"]' secrets/sops/cylon-link-hostkey.yaml | cmp - "$kd/ssh_host_ed25519_key" && echo "private key round-trips"
grep -c 'recipient: age1' secrets/sops/cylon-link-hostkey.yaml
grep -c 'recipient: age1' secrets/sops/common.yaml
```

Expected:
- `host can decrypt`
- `private key round-trips`
- `1` (only the user key can open the host-key file)
- `11` (`common.yaml` was 10 recipients)

If the `cmp` fails only because of a trailing newline, keep the secret as it is and write the file in Task 6 with `printf '%s\n'`. Record which case applied.

- [ ] **Step 6: Destroy the plaintext and commit**

```bash
shred -u "$kd"/* && rmdir "$kd"
git add .sops.yaml secrets/sops/cylon-link-hostkey.yaml secrets/sops/common.yaml
git commit -m "feat(secrets): add cylon-link host key and sops recipient"
```

---

### Task 4: Host configuration and fleet plumbing

**Files:**
- Create: `hosts/cylon-link/configuration.nix`
- Create: `hosts/cylon-link/hardware.nix`
- Create: `hosts/cylon-link/boot/default.nix`
- Create: `hosts/cylon-link/config-test.nix`
- Modify: `flake-modules/lib.nix:76` (`lightHosts`)
- Modify: `flake-modules/hosts.nix:30-45` (`ciMatrix`)
- Modify: `flake-modules/checks.nix` (second check)

**Interfaces:**
- Consumes:
  - `hosts/cylon-link/boot/package.nix` (Task 1)
  - `constellation.common.minimal` (Task 2)
  - the `host_cylon_link` recipient on `common.yaml` (Task 3)
- Produces:
  - `nixosConfigurations.cylon-link` and `deployTargets.cylon-link`
  - `config.system.build.cylonLinkBoot`, an x86_64 `cylon-link-boot` derivation
  - the flake attribute `ciExcludedHosts`
  - the check `checks.x86_64-linux.cylon-link-config`

- [ ] **Step 1: Write the failing check**

Create `hosts/cylon-link/config-test.nix`:

```nix
# Design invariants for cylon-link that a refactor could silently break,
# plus the kernel options the board needs. Neither half needs the full
# kernel build. See docs/superpowers/specs/2026-09-16-cylon-link-design.md.
{
  self,
  pkgs,
}: let
  inherit (pkgs) lib;
  c = self.nixosConfigurations.cylon-link.config;
  names = map (p: p.name or "") c.environment.systemPackages;
  check = cond: msg: lib.assertMsg cond "cylon-link: ${msg}";
in
  assert check (c.nixpkgs.hostPlatform.system == "armv7l-linux") "must target armv7l-linux";
  assert check (c.nixpkgs.buildPlatform.system == "x86_64-linux") "must be cross-compiled from x86_64-linux";
  assert check (self.deployTargets.cylon-link.system == "x86_64-linux") "just deploy only builds x86_64/aarch64 attributes";
  assert check (!(builtins.elem "cylon-link" (map (e: e.host) self.ciMatrix))) "must stay out of CI";
  assert check (!(c ? home-manager)) "must not get home-manager";
  assert check (!c.determinate.enable) "Determinate Nix has no armv7l build";
  assert check c.constellation.common.minimal "needs the minimal baseline";
  assert check (!builtins.any (n: lib.hasPrefix "ffmpeg" n) names) "the full tool list leaked in";
  assert check (c.nix.settings.max-jobs == 0) "the device must never build";
  assert check (!c.constellation.virtualization.enable) "virtualization is too heavy";
  assert check (!c.constellation.netdataClient.enable) "netdata is too heavy";
  assert check c.boot.loader.external.enable "must boot through the kexec chain";
  assert check (c.fileSystems."/".device == "/dev/disk/by-label/CYLON_ROOT") "root must be CYLON_ROOT";
  assert check (c.fileSystems."/boot/steamlink".device == "/dev/disk/by-label/CYLON_BOOT") "the install hook needs CYLON_BOOT mounted";
  assert check (c.hardware.deviceTree.name == "berlin2cd-valve-steamlink.dtb") "wrong device tree";
  assert check (c.services.tailscale.authKeyFile == c.sops.secrets.tailscale-key.path) "must join the tailnet unattended";
  assert check (c.sops.secrets.tailscale-key.sopsFile == c.constellation.sops.commonSopsFile) "the Tailscale key comes from common.yaml";
    pkgs.runCommand "cylon-link-config" {} ''
      config=${c.boot.kernelPackages.kernel.configfile}
      for opt in ARCH_BERLIN=y MACH_BERLIN_BG2CD=y USB_EHCI_HCD=y USB_CHIPIDEA_HOST=y \
                 PHY_BERLIN_USB=y USB_STORAGE=y BLK_DEV_SD=y EXT4_FS=y SERIAL_8250_DW=y \
                 KEXEC=y 'PXA168_ETH=[ym]'; do
        grep -qxE "CONFIG_$opt" "$config" || { echo "kernel config lacks CONFIG_$opt" >&2; exit 1; }
      done
      touch $out
    ''
```

In `flake-modules/checks.nix`, extend the x86_64-only attribute set from Task 1:

```nix
        cylon-link-config = import ../hosts/cylon-link/config-test.nix {
          inherit self;
          pkgs = inputs.nixpkgs.legacyPackages.${system};
        };
```

- [ ] **Step 2: Run the check to see it fail**

```bash
git add -N hosts/cylon-link/config-test.nix
nix build .#checks.x86_64-linux.cylon-link-config -L
```

Expected: FAIL with `attribute 'cylon-link' missing`.

- [ ] **Step 3: Write `hardware.nix`**

Create `hosts/cylon-link/hardware.nix`:

```nix
# Valve Steam Link (2015): Marvell Berlin BG2CD, one Cortex-A9 core, 512 MB.
{pkgs, ...}: {
  # Cross-compiled on raider. nixpkgs caches nothing for armv7l, and a native
  # build on basestar spent 86 minutes without finishing the toolchain
  # (docs/superpowers/specs/2026-09-16-cylon-link-design.md).
  nixpkgs.hostPlatform = "armv7l-linux";
  nixpkgs.buildPlatform = "x86_64-linux";

  # multi_v7_defconfig already has every driver this board needs. autoModules
  # would build the rest of the tree as modules, which dominated the build.
  boot.kernelPackages = pkgs.linuxPackagesFor (pkgs.linuxPackages.kernel.override {autoModules = false;});
  boot.kernelParams = ["console=ttyS0,115200n8" "usbcore.autosuspend=-1"];
  hardware.deviceTree.name = "berlin2cd-valve-steamlink.dtb";

  # USB storage, SCSI disks and ext4 are built in. The default initrd list
  # names PC storage modules this kernel does not have.
  boot.initrd.includeDefaultModules = false;

  fileSystems."/" = {
    device = "/dev/disk/by-label/CYLON_ROOT";
    fsType = "ext4";
    options = ["noatime"];
  };

  # Wired only. The mwifiex SDIO radio works under this kernel but is out of
  # scope.
  networking.useNetworkd = true;
  networking.useDHCP = true;
}
```

- [ ] **Step 4: Write `boot/default.nix`**

Create `hosts/cylon-link/boot/default.nix`:

```nix
# The NixOS half of cylon-link's boot chain. The firmware half, and the
# protocol between them, is documented in run.sh.
{
  config,
  lib,
  pkgs,
  ...
}: let
  p1 = "/boot/steamlink";

  # Adds kexec to Valve's 3.8.13 kernel, which lacks it. Built by
  # djmuted/steamlink-debian (GPL), which ships the binary without its source.
  # Byte-identical to the copy in the Debian image this host replaced.
  kexecModule = pkgs.fetchurl {
    url = "https://raw.githubusercontent.com/djmuted/steamlink-debian/216b58b6e9bb4ba20a9648d1ef089d7b6dbb58df/rootfs/boot/kexec_load.ko";
    hash = "sha256-sbinlkoG1+vNRRcLZWX22eNIxfyIXro65/yBj0BLGVY=";
  };

  bootToolFor = p:
    p.callPackage ./package.nix {
      # Static musl: it runs under the 3.8 kernel, which nixpkgs' glibc refuses.
      kexec = "${pkgs.pkgsStatic.kexec-tools}/bin/kexec";
      kexecModule = "${kexecModule}";
      dtbName = config.hardware.deviceTree.name;
    };
  bootTool = bootToolFor pkgs;
in {
  fileSystems.${p1} = {
    device = "/dev/disk/by-label/CYLON_BOOT";
    # CYLON_BOOT is ext3 so Valve's kernel can read it. The ext4 driver mounts
    # it without changing its on-disk features.
    fsType = "ext4";
    options = ["noatime"];
  };

  boot.loader.external = {
    enable = true;
    installHook = pkgs.writeShellScript "cylon-link-install-hook" ''
      exec ${lib.getExe bootTool} install "$1" ${p1}
    '';
  };

  # "Booted OK" means deployable, so wait for Tailscale. An entry this unit
  # never confirms is not retried on the next power cycle.
  systemd.services.cylon-link-boot-ok = {
    description = "Record this cylon-link boot entry as good";
    wantedBy = ["multi-user.target"];
    wants = ["network-online.target"];
    after = ["network-online.target" "tailscaled.service"];
    unitConfig.RequiresMountsFor = p1;
    path = [config.services.tailscale.package];
    # A switch must not re-run it: /proc/cmdline still describes the boot.
    restartIfChanged = false;
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      TimeoutStartSec = "6min";
    };
    script = ''
      for _ in $(seq 60); do
        if tailscale status >/dev/null 2>&1; then
          exec ${lib.getExe bootTool} confirm ${p1} /proc/cmdline
        fi
        sleep 5
      done
      echo "Tailscale never came up; this boot entry stays unconfirmed" >&2
      exit 1
    '';
  };

  # Build-platform copy for `just flash-cylon-link`.
  system.build.cylonLinkBoot = bootToolFor pkgs.buildPackages;
}
```

- [ ] **Step 5: Write `configuration.nix`**

Create `hosts/cylon-link/configuration.nix`:

```nix
# cylon-link: a Valve Steam Link running NixOS as an always-on helper.
# It boots through Valve's firmware and kexec; see ./boot and CLAUDE.md.
{config, ...}: {
  imports = [
    ./hardware.nix
    ./boot
  ];

  networking.hostName = "cylon-link";

  constellation.common.minimal = true;
  constellation.sops.enable = true;
  # Too heavy for 500 MB of RAM and a cross build.
  constellation.virtualization.enable = false;
  constellation.netdataClient.enable = false;
  # Determinate publishes no armv7l build, so use nixpkgs' Nix.
  determinate.enable = false;

  sops.secrets.tailscale-key.sopsFile = config.constellation.sops.commonSopsFile;
  services.tailscale.authKeyFile = config.sops.secrets.tailscale-key.path;

  # The device never compiles. A path missing from cache.arsfeld.dev should
  # fail the deploy, not start a build on one Cortex-A9 core.
  nix.settings.max-jobs = 0;

  system.stateVersion = "26.05";
}
```

- [ ] **Step 6: Fleet plumbing**

In `flake-modules/lib.nix`, change line 76 to:

```nix
    lightHosts = ["raspi3" "octopi" "r2s" "cylon-link"];
```

In `flake-modules/hosts.nix`, add before the `ciMatrix` comment:

```nix
    # Hosts CI never builds. cylon-link is cross-compiled for armv7l and its
    # kernel alone outlasts the build job's 120-minute timeout on a GitHub
    # runner. raider builds it in `just deploy` phase 1 instead.
    ciExcludedHosts = ["cylon-link"];
```

In `ciMatrix`, replace the final `self.hosts;` with:

```nix
      (builtins.filter (h: !(builtins.elem h self.ciExcludedHosts)) self.hosts);
```

- [ ] **Step 7: Track the files and run the check**

```bash
git add -N hosts/cylon-link/configuration.nix hosts/cylon-link/hardware.nix hosts/cylon-link/boot/default.nix
nix eval --raw .#nixosConfigurations.cylon-link.config.system.build.toplevel.drvPath
nix build .#checks.x86_64-linux.cylon-link-config -L
nix eval --json .#ciMatrix --apply 'map (e: e.host)'
```

Expected:
- a `.drv` path
- the check builds (it generates the kernel config, which takes a few minutes)
- the matrix lists nine hosts and no `cylon-link`

If evaluation fails in `pkgs.linuxPackages.kernel.override`, use `pkgs.linux.override {autoModules = false;}` instead and re-run.

- [ ] **Step 8: Format and commit**

```bash
just fmt
git add hosts/cylon-link flake-modules/lib.nix flake-modules/hosts.nix flake-modules/checks.nix
git commit -m "feat(cylon-link): add Steam Link host"
```

---

### Task 5: Build the system on raider

**Files:**
- Modify (only if the build requires it): `hosts/cylon-link/hardware.nix`, `modules/constellation/common.nix` (the minimal list)

**Interfaces:**
- Consumes: `deployTargets.cylon-link` and `system.build.cylonLinkBoot` (Task 4).
- Produces: a built toplevel in raider's store, plus the measured build time and closure size, for the docs in Task 9.

- [ ] **Step 1: Start the build as a user unit**

```bash
S=/tmp/claude-1000/-home-arosenfeld-Code-nixos/cylon-link
systemd-run --user --unit=cylon-link-build --collect --working-directory="$PWD" \
  --setenv=PATH="$PATH" -p StandardOutput="file:$S/build.log" -p StandardError="file:$S/build.log" \
  bash -c 'start=$(date +%s); nix build --no-link --print-out-paths -L .#deployTargets.cylon-link .#nixosConfigurations.cylon-link.config.system.build.cylonLinkBoot; echo "exit=$? seconds=$(( $(date +%s) - start ))"'
```

- [ ] **Step 2: Wait for it to finish**

Poll `systemctl --user is-active cylon-link-build` until it reports `inactive`, then read the end of `$S/build.log`.

Expected: `exit=0`, preceded by two store paths (the toplevel and `cylon-link-boot`). Record `seconds`.

On failure, find the first `error:` in the log and apply the matching fix:
- **`modprobe: FATAL: Module … not found` while building the initrd.** Check that module's option in the kernel config: `grep CONFIG_<NAME> $(nix build --no-link --print-out-paths .#nixosConfigurations.cylon-link.config.boot.kernelPackages.kernel.configfile)`.
  - If it is `=y` or unneeded on this board, add `boot.initrd.allowMissingModules = true;` to `hardware.nix`, with a comment naming the module.
  - Otherwise, add the missing option to `boot.kernelPatches = [{name = "cylon-link"; patch = null; structuredExtraConfig = with lib.kernel; {<NAME> = yes;};}];`.
- **A package in the minimal list fails to cross-compile.** Remove it from the minimal list in `common.nix`.
- **Any other package fails to cross-compile.** Find what pulls it in with `nix why-depends --derivation .#deployTargets.cylon-link <failing .drv>`. Disable that feature on this host in `configuration.nix`, with a comment saying why.

After each fix, re-run Step 1.

- [ ] **Step 3: Inspect the result**

```bash
top=$(nix build --no-link --print-out-paths .#deployTargets.cylon-link)
tool=$(nix build --no-link --print-out-paths .#nixosConfigurations.cylon-link.config.system.build.cylonLinkBoot)
nix path-info -Sh "$top"
ls -l "$top/dtbs/berlin2cd-valve-steamlink.dtb"
cat "$top/kernel-params"; echo
file "$tool/bin/cylon-link-boot"
grep -o 'KEXEC=[^ ]*' "$tool/bin/cylon-link-boot" | head -1 | cut -d= -f2 | tr -d "'" | xargs file
```

Expected:
- a closure well under 1 GiB
- the dtb exists
- `kernel-params` contains `console=ttyS0,115200n8 usbcore.autosuspend=-1`
- `cylon-link-boot` is a script
- `KEXEC` points to an `ELF 32-bit LSB executable, ARM … statically linked` binary

- [ ] **Step 4: Commit any fixes**

```bash
just fmt
git add -A hosts/cylon-link modules/constellation/common.nix
git commit -m "fix(cylon-link): allow missing initrd modules"   # name the actual fix
```

Skip this step if Step 2 passed first time. Otherwise the subject names the fix, for example `fix(cylon-link): drop tcpdump from the minimal list`.

---

### Task 6: `just flash-cylon-link`

**Files:**
- Create: `hosts/cylon-link/flash.sh`
- Modify: `justfile` (new recipe after `build-octopi`)

**Interfaces:**
- Consumes: `deployTargets.cylon-link`, `system.build.cylonLinkBoot`, `secrets/sops/cylon-link-hostkey.yaml`.
- Produces:
  - `hosts/cylon-link/flash.sh DEVICE TOPLEVEL BOOT_TOOL KEY_DIR`, run as root. `BOOT_TOOL` is the path to the `cylon-link-boot` binary. `KEY_DIR` holds `ssh_host_ed25519_key{,.pub}`.
  - The recipe `just flash-cylon-link DEVICE`.

- [ ] **Step 1: Write `flash.sh`**

Create `hosts/cylon-link/flash.sh`:

```bash
#!/usr/bin/env bash
# Writes a bootable cylon-link USB stick. Run as root; `just flash-cylon-link`
# guards DEVICE, builds everything and decrypts the host key first.
#
# Usage: flash.sh DEVICE TOPLEVEL BOOT_TOOL KEY_DIR
#   DEVICE     whole block device, erased
#   TOPLEVEL   cylon-link system closure, already built
#   BOOT_TOOL  build-platform cylon-link-boot binary
#   KEY_DIR    directory holding ssh_host_ed25519_key and its .pub
# mkfs.ext3/mkfs.ext4 and nix must be on PATH.
set -euo pipefail

dev=$1 toplevel=$2 boot_tool=$3 key_dir=$4
work=$(mktemp -d)

cleanup() {
  umount "$work/p1" "$work/p2" 2>/dev/null || true
  rmdir "$work/p1" "$work/p2" "$work" 2>/dev/null || true
}
trap cleanup EXIT

# part N: path of partition N, for by-id, sdX and loopN/nvmeXnY names alike.
part() {
  case $dev in
  /dev/disk/by-id/*) echo "$dev-part$1" ;;
  *[0-9]) echo "${dev}p$1" ;;
  *) echo "$dev$1" ;;
  esac
}

wipefs --all --quiet "$dev"
# p1: 1 GiB of firmware-visible boot material. p2: the rest.
printf 'label: dos\n,1GiB,L\n,,L\n' | sfdisk --quiet "$dev"
udevadm settle
p1=$(part 1) p2=$(part 2)

# Valve's 3.8 kernel reads p1: plain ext3, as djmuted's Debian image made it.
mkfs.ext3 -q -F -L CYLON_BOOT "$p1"
# Only NixOS reads p2, so it gets current ext4 defaults.
mkfs.ext4 -q -F -L CYLON_ROOT "$p2"

mkdir "$work/p1" "$work/p2"
mount "$p2" "$work/p2"
mount "$p1" "$work/p1"

echo "Copying $toplevel ..."
nix copy --no-check-sigs --to "local?root=$work/p2" "$toplevel"
nix-env --store "$work/p2" -p "$work/p2/nix/var/nix/profiles/system" --set "$toplevel"
mkdir -p "$work/p2/etc/ssh"
touch "$work/p2/etc/NIXOS"
install -m 0600 "$key_dir/ssh_host_ed25519_key" "$work/p2/etc/ssh/ssh_host_ed25519_key"
install -m 0644 "$key_dir/ssh_host_ed25519_key.pub" "$work/p2/etc/ssh/ssh_host_ed25519_key.pub"

# No good entry yet: if this first boot fails, the stock firmware stays up.
"$boot_tool" install "$toplevel" "$work/p1"
sync
echo "Stick written."
```

- [ ] **Step 2: Write the recipe**

Add to `justfile` after `build-octopi`:

```just
# Write a bootable cylon-link (Steam Link) USB stick. ERASES DEVICE, which
# must be a whole-disk /dev/disk/by-id/usb-* path. Run inside `nix develop`.
flash-cylon-link DEVICE:
    #!/usr/bin/env bash
    set -euo pipefail
    dev='{{ DEVICE }}'
    case "$dev" in
      /dev/disk/by-id/usb-*-part*) echo "refusing: $dev is a partition; pass the whole disk" >&2; exit 1 ;;
      /dev/disk/by-id/usb-*) ;;
      *) echo "refusing: DEVICE must be a /dev/disk/by-id/usb-* path" >&2; exit 1 ;;
    esac
    [ -b "$dev" ] || { echo "refusing: $dev is not a block device" >&2; exit 1; }
    if lsblk -nro MOUNTPOINTS "$dev" | grep -q .; then
      echo "refusing: $dev has mounted filesystems" >&2; exit 1
    fi
    command -v sops >/dev/null || { echo "sops not found; run inside 'nix develop'" >&2; exit 1; }

    echo "Building cylon-link..."
    toplevel=$(nix build --no-link --print-out-paths '.#deployTargets.cylon-link')
    boot_tool=$(nix build --no-link --print-out-paths '.#nixosConfigurations.cylon-link.config.system.build.cylonLinkBoot')
    e2fsprogs=$(nix build --no-link --print-out-paths --inputs-from . 'nixpkgs#e2fsprogs.bin')

    key_dir=$(mktemp -d "${XDG_RUNTIME_DIR:-/tmp}/cylon-link-key.XXXXXX")
    trap 'rm -rf "$key_dir"' EXIT
    secret=secrets/sops/cylon-link-hostkey.yaml
    sops --decrypt --extract '["ssh_host_ed25519_key"]' "$secret" >"$key_dir/ssh_host_ed25519_key"
    sops --decrypt --extract '["ssh_host_ed25519_key_pub"]' "$secret" >"$key_dir/ssh_host_ed25519_key.pub"

    lsblk -o NAME,SIZE,MODEL,SERIAL,FSTYPE,LABEL "$dev"
    read -r -p "Erase everything on $dev? [y/N] " answer
    [ "$answer" = y ] || { echo "aborted"; exit 1; }

    sudo env PATH="$e2fsprogs/bin:$PATH" bash hosts/cylon-link/flash.sh \
      "$dev" "$toplevel" "$boot_tool/bin/cylon-link-boot" "$key_dir"
    udisksctl power-off -b "$(readlink -f "$dev")"
    echo "Done: move the stick to the Steam Link, plug in Ethernet, and power-cycle it."
```

If Task 3 Step 5 found that the private key comes back without a trailing newline, change the first `sops` line to `printf '%s\n' "$(sops --decrypt --extract '["ssh_host_ed25519_key"]' "$secret")" >"$key_dir/ssh_host_ed25519_key"`.

- [ ] **Step 3: Test the guards**

```bash
just flash-cylon-link /dev/sda; echo "exit=$?"
just flash-cylon-link /dev/disk/by-id/usb-Kingston_DataTraveler_3.0_1C6F654E4168F290E9213192-0:0-part1; echo "exit=$?"
```

Expected: both print `refusing: …` and `exit=1`. Nothing is built or touched.

- [ ] **Step 4: Test `flash.sh` on a loop device**

This runs inside `nix develop`, with `$S` from Task 5.

```bash
img=$S/stick.img; rm -f "$img"; truncate -s 4G "$img"
loop=$(sudo losetup --show -fP "$img")
top=$(nix build --no-link --print-out-paths .#deployTargets.cylon-link)
tool=$(nix build --no-link --print-out-paths .#nixosConfigurations.cylon-link.config.system.build.cylonLinkBoot)
e2fs=$(nix build --no-link --print-out-paths --inputs-from . 'nixpkgs#e2fsprogs.bin')
kd=$(mktemp -d "$XDG_RUNTIME_DIR/cylon-link-key.XXXXXX")
sops --decrypt --extract '["ssh_host_ed25519_key"]' secrets/sops/cylon-link-hostkey.yaml >"$kd/ssh_host_ed25519_key"
sops --decrypt --extract '["ssh_host_ed25519_key_pub"]' secrets/sops/cylon-link-hostkey.yaml >"$kd/ssh_host_ed25519_key.pub"
sudo env PATH="$e2fs/bin:$PATH" bash hosts/cylon-link/flash.sh "$loop" "$top" "$tool/bin/cylon-link-boot" "$kd"
rm -rf "$kd"

# Inspect. p1 read-only; p2 read-write because `nix path-info` opens the
# store database for writing (the image is thrown away afterwards).
m=$(mktemp -d); mkdir "$m/p1" "$m/p2"
sudo mount -o ro "${loop}p1" "$m/p1"; sudo mount "${loop}p2" "$m/p2"
sudo "$e2fs/bin/dumpe2fs" -h "${loop}p1" 2>/dev/null | grep -E '^(Filesystem volume name|Filesystem features)'
sudo "$e2fs/bin/dumpe2fs" -h "${loop}p2" 2>/dev/null | grep -E '^Filesystem volume name'
cmp "$m/p1/steamlink/factory_test/run.sh" hosts/cylon-link/boot/run.sh && echo "run.sh ok"
sha256sum "$m/p1/steamlink/kexec_load.ko"
file "$m/p1/steamlink/bin/kexec"
ls "$m/p1/nixos"; cat "$m/p1/nixos/new/cmdline"
readlink "$m/p2/nix/var/nix/profiles/system" "$m/p2/nix/var/nix/profiles/system-1-link"
sudo stat -c '%a %n' "$m/p2/etc/ssh/ssh_host_ed25519_key"
ssh-keygen -lf "$m/p2/etc/ssh/ssh_host_ed25519_key.pub"
sudo nix path-info --store "local?root=$m/p2" "$top" >/dev/null && echo "closure registered"
sudo umount "$m/p1" "$m/p2"; rmdir "$m/p1" "$m/p2" "$m"; sudo losetup -d "$loop"; rm -f "$img"
```

Expected:
- **p1:**
  - `CYLON_BOOT`, with features exactly `has_journal ext_attr resize_inode dir_index filetype sparse_super large_file`. That is the Debian image's set, which the stock kernel mounted.
  - `run.sh ok`
  - `kexec_load.ko` sha256 `b1b8a7964a06d7ebcd45170b6565f6d9e348c5fc885eba3ae7fc818f404b1956`
  - `kexec` is `ELF 32-bit … ARM … statically linked`
  - `ls nixos` shows only `new`, and `cmdline` ends with `init=$top/init`
- **p2:**
  - `CYLON_ROOT`
  - the system profile resolves to `system-1-link`, which resolves to `$top`
  - the host key has mode `600`, and its fingerprint comment reads `root@cylon-link`
  - `closure registered`

- [ ] **Step 5: Commit**

```bash
git add hosts/cylon-link/flash.sh justfile
git commit -m "feat(cylon-link): add just flash-cylon-link"
```

---

### Task 6b: Flash a disk image instead of copying files

Added 2026-09-17 after the first real flash. The Kingston stick sits on a USB 2.0 port, and writing a store file by file averaged 0.32 MB/s, falling to about 46 KB/s. After 30 minutes about 950 MB was still unwritten, and the flash was abandoned. Its sequential writes are fine. This task makes `just flash-cylon-link` write a prebuilt image with `dd`, modelled on nixpkgs' `nixos/modules/installer/sd-card/sd-image.nix`.

**Files:**
- Create: `hosts/cylon-link/image.nix`
- Modify: `hosts/cylon-link/configuration.nix` (imports)
- Modify: `hosts/cylon-link/flash.sh` (rewritten)
- Modify: `justfile` (`flash-cylon-link` body)
- Modify: `hosts/cylon-link/config-test.nix` (two assertions)

**Interfaces:**
- Consumes: `config.system.build.cylonLinkBoot` (the build-platform `cylon-link-boot`, Task 4) and `config.system.build.toplevel`.
- Produces:
  - `config.system.build.cylonLinkImage`, a zstd-compressed raw MBR disk image. p1 is `CYLON_BOOT` (ext3, 1 GiB, staged by `cylon-link-boot install`, no `good` entry). p2 is `CYLON_ROOT` (ext4, sized to the closure, containing `/nix-path-registration` and an empty `/etc/ssh`).
  - Two first-boot units: `cylon-link-grow-root.service` and `cylon-link-register-store.service`.
  - `hosts/cylon-link/flash.sh DEVICE IMAGE KEY_DIR`, run as root, with `zstd` on PATH.

- [ ] **Step 1: Write the failing check**

In `hosts/cylon-link/config-test.nix`, add these two assertions after the `hardware.deviceTree.name` one:

```nix
  assert check (c.system.build ? cylonLinkImage) "just flash-cylon-link needs the disk image";
  assert check (c.systemd.services ? cylon-link-register-store && c.systemd.services ? cylon-link-grow-root) "a flashed image must register its store and grow on first boot";
```

Run: `nix build .#checks.x86_64-linux.cylon-link-config -L`
Expected: FAIL with `cylon-link: just flash-cylon-link needs the disk image`.

- [ ] **Step 2: Write `image.nix`**

Create `hosts/cylon-link/image.nix`:

```nix
# cylon-link's flashable disk image and the first-boot units it relies on.
# `just flash-cylon-link` writes it with dd. The Kingston stick manages about
# 46 KB/s at small scattered writes, so copying a store onto it file by file
# takes hours, while one sequential write takes about a minute. Modelled on
# nixpkgs' sd-image.nix, with an ext3 CYLON_BOOT partition instead of a FAT
# firmware partition.
{
  config,
  lib,
  pkgs,
  modulesPath,
  ...
}: let
  inherit (config.system.build) toplevel;
  registration = "/nix-path-registration";

  rootfs = pkgs.callPackage (modulesPath + "/../lib/make-ext4-fs.nix") {
    storePaths = [toplevel];
    compressImage = true;
    volumeLabel = "CYLON_ROOT";
    # The host key is written after flashing, never into the store. This only
    # creates its directory.
    populateImageCommands = ''
      mkdir -p ./files/etc/ssh
    '';
  };
in {
  system.build.cylonLinkImage =
    pkgs.runCommand "cylon-link.img.zst" {
      nativeBuildInputs = with pkgs.buildPackages; [e2fsprogs.bin fakeroot libfaketime util-linux zstd];
    } ''
      # p1: what Valve's firmware reads, staged exactly as the NixOS install
      # hook stages it. No good entry: if the first boot fails, the stock
      # firmware stays up.
      mkdir p1
      ${lib.getExe config.system.build.cylonLinkBoot} install ${toplevel} p1
      truncate -s 1G p1.img
      faketime -f "1970-01-01 00:00:01" fakeroot mkfs.ext3 -q -L CYLON_BOOT -d p1 p1.img

      zstd -d --no-progress ${rootfs} -o p2.img

      start=2048
      p1Sectors=$(( $(stat -c %s p1.img) / 512 ))
      p2Sectors=$(( $(stat -c %s p2.img) / 512 ))
      truncate -s $(( (start + p1Sectors + p2Sectors) * 512 )) disk.img
      sfdisk --no-reread --no-tell-kernel disk.img <<EOF
      label: dos
      start=$start, size=$p1Sectors, type=83
      start=$(( start + p1Sectors )), size=$p2Sectors, type=83
      EOF
      dd conv=notrunc bs=4M oflag=seek_bytes if=p1.img of=disk.img seek=$(( start * 512 ))
      dd conv=notrunc bs=4M oflag=seek_bytes if=p2.img of=disk.img seek=$(( (start + p1Sectors) * 512 ))
      zstd -T$NIX_BUILD_CORES --no-progress disk.img -o $out
    '';

  # First boot of a flashed image: grow CYLON_ROOT over the rest of the
  # stick. From sd-image.nix, except that the partition number comes from
  # sysfs. sd-image derives it from the minor number, which is only right for
  # the first disk.
  systemd.services.cylon-link-grow-root = {
    description = "Grow CYLON_ROOT to fill the USB stick";
    unitConfig = {
      DefaultDependencies = false;
      ConditionPathExists = registration;
    };
    wantedBy = ["sysinit.target"];
    before = ["sysinit.target" "shutdown.target" "cylon-link-register-store.service"];
    after = ["local-fs.target"];
    conflicts = ["shutdown.target"];
    restartIfChanged = false;
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    path = [pkgs.util-linux pkgs.e2fsprogs];
    script = ''
      part=$(readlink -f "$(findmnt -n -o SOURCE /)")
      disk=$(lsblk -npo PKNAME "$part")
      num=$(cat "/sys/class/block/''${part##*/}/partition")
      echo ",+," | sfdisk -N"$num" --no-reread "$disk"
      partx -u --nr "$num" "$disk"
      resize2fs "$part"
    '';
  };

  # First boot of a flashed image: load the store registration that
  # make-ext4-fs wrote, and create the system profile. From sd-image.nix.
  systemd.services.cylon-link-register-store = {
    description = "Register the flashed Nix store";
    unitConfig = {
      DefaultDependencies = false;
      ConditionPathExists = registration;
    };
    wantedBy = ["sysinit.target"];
    before = ["sysinit.target" "shutdown.target" "nix-daemon.socket" "nix-daemon.service"];
    after = ["local-fs.target"];
    conflicts = ["shutdown.target"];
    restartIfChanged = false;
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      ${lib.getExe' config.nix.package.out "nix-store"} --load-db < ${registration}
      touch /etc/NIXOS
      ${lib.getExe' config.nix.package.out "nix-env"} -p /nix/var/nix/profiles/system --set /run/current-system
      rm -f ${registration}
    '';
  };
}
```

Add `./image.nix` to the `imports` list in `hosts/cylon-link/configuration.nix`, after `./boot`.

- [ ] **Step 3: Build the image and run the check**

```bash
git add -N hosts/cylon-link/image.nix
nix build .#checks.x86_64-linux.cylon-link-config -L
img=$(nix build --no-link --print-out-paths .#nixosConfigurations.cylon-link.config.system.build.cylonLinkImage)
ls -l "$img"; zstd -lv "$img" | grep -E 'Decompressed Size|Ratio'
```

Expected: the check passes. The image is a few hundred MB compressed, and roughly 1 GiB plus the closure size decompressed. It builds in minutes, because the closure is already in raider's store; run it as a `systemd-run --user` unit if it takes longer than your command timeout.

- [ ] **Step 4: Rewrite `flash.sh`**

Replace `hosts/cylon-link/flash.sh` with:

```bash
#!/usr/bin/env bash
# Writes the cylon-link disk image to a USB stick and installs the host key.
# Run as root; `just flash-cylon-link` guards DEVICE, builds the image and
# decrypts the key first.
#
# Usage: flash.sh DEVICE IMAGE KEY_DIR
#   DEVICE   whole block device, erased
#   IMAGE    zstd-compressed disk image (system.build.cylonLinkImage)
#   KEY_DIR  directory holding ssh_host_ed25519_key and its .pub
# zstd must be on PATH.
set -euo pipefail

dev=$1 image=$2 key_dir=$3
mnt=$(mktemp -d)

cleanup() {
  umount "$mnt" 2>/dev/null || true
  rmdir "$mnt" 2>/dev/null || true
}
trap cleanup EXIT

# part N: path of partition N, for by-id, sdX and loopN/nvmeXnY names alike.
part() {
  case $dev in
  /dev/disk/by-id/*) echo "$dev-part$1" ;;
  *[0-9]) echo "${dev}p$1" ;;
  *) echo "$dev$1" ;;
  esac
}

wipefs --all --quiet "$dev"
# One sequential write. This stick is unusably slow at small scattered ones.
zstd -dc "$image" | dd of="$dev" bs=4M iflag=fullblock oflag=direct conv=fsync status=progress
blockdev --rereadpt "$dev"
udevadm settle

# The host key never enters the store, so it goes in after the image.
mount "$(part 2)" "$mnt"
install -m 0600 "$key_dir/ssh_host_ed25519_key" "$mnt/etc/ssh/ssh_host_ed25519_key"
install -m 0644 "$key_dir/ssh_host_ed25519_key.pub" "$mnt/etc/ssh/ssh_host_ed25519_key.pub"
umount "$mnt"
sync
echo "Stick written."
```

- [ ] **Step 5: Update the recipe**

In `justfile`'s `flash-cylon-link`, replace the three `nix build` lines with:

```bash
    image=$(nix build --no-link --print-out-paths '.#nixosConfigurations.cylon-link.config.system.build.cylonLinkImage')
    zstd=$(nix build --no-link --print-out-paths --inputs-from . 'nixpkgs#zstd.bin')
```

(Change the `echo "Building cylon-link..."` text to `echo "Building the cylon-link image..."`.) Replace the `sudo env … flash.sh …` call with:

```bash
    sudo env PATH="$zstd/bin:$PATH" bash hosts/cylon-link/flash.sh "$dev" "$image" "$key_dir"
```

Leave the guards, key decryption, confirmation prompt and power-off unchanged.

- [ ] **Step 6: Test on a loop device**

As one script, inside `nix develop`, with `S=.superpowers/sdd/2026-09-16-cylon-link/scratch`. The image is already built; the loop file must be at least the decompressed image size, so use 4 GiB.

```bash
img=$(nix build --no-link --print-out-paths .#nixosConfigurations.cylon-link.config.system.build.cylonLinkImage)
top=$(nix build --no-link --print-out-paths .#deployTargets.cylon-link)
zstd=$(nix build --no-link --print-out-paths --inputs-from . 'nixpkgs#zstd.bin')
e2fs=$(nix build --no-link --print-out-paths --inputs-from . 'nixpkgs#e2fsprogs.bin')
file=$S/stick.img; rm -f "$file"; truncate -s 4G "$file"
loop=$(sudo losetup --show -fP "$file")
kd=$(mktemp -d "$XDG_RUNTIME_DIR/cylon-link-key.XXXXXX")
sops --decrypt --extract '["ssh_host_ed25519_key"]' secrets/sops/cylon-link-hostkey.yaml >"$kd/ssh_host_ed25519_key"
sops --decrypt --extract '["ssh_host_ed25519_key_pub"]' secrets/sops/cylon-link-hostkey.yaml >"$kd/ssh_host_ed25519_key.pub"
time sudo env PATH="$zstd/bin:$PATH" bash hosts/cylon-link/flash.sh "$loop" "$img" "$kd"
rm -rf "$kd"

sudo "$e2fs/bin/e2fsck" -fn "${loop}p1"; sudo "$e2fs/bin/e2fsck" -fn "${loop}p2"
sudo "$e2fs/bin/dumpe2fs" -h "${loop}p1" 2>/dev/null | grep -E '^(Filesystem volume name|Filesystem features)'
sudo "$e2fs/bin/dumpe2fs" -h "${loop}p2" 2>/dev/null | grep -E '^Filesystem volume name'
m=$(mktemp -d); mkdir "$m/p1" "$m/p2"
sudo mount -o ro "${loop}p1" "$m/p1"; sudo mount -o ro "${loop}p2" "$m/p2"
cmp "$m/p1/steamlink/factory_test/run.sh" hosts/cylon-link/boot/run.sh && echo "run.sh ok"
sha256sum "$m/p1/steamlink/kexec_load.ko"; file "$m/p1/steamlink/bin/kexec"
ls "$m/p1/nixos"; cat "$m/p1/nixos/new/cmdline"
[ -d "$m/p2$top" ] && echo "toplevel present"
[ -s "$m/p2/nix-path-registration" ] && grep -c "^/nix/store/" "$m/p2/nix-path-registration"
sudo stat -c '%a %n' "$m/p2/etc/ssh/ssh_host_ed25519_key"; ssh-keygen -lf "$m/p2/etc/ssh/ssh_host_ed25519_key.pub"
sudo umount "$m/p1" "$m/p2"; rmdir "$m/p1" "$m/p2" "$m"; sudo losetup -d "$loop"; rm -f "$file"
```

Expected:
- the flash completes (report the `time`)
- both `e2fsck` runs are clean
- **p1:** `CYLON_BOOT`, with features exactly `has_journal ext_attr resize_inode dir_index filetype sparse_super large_file`; `run.sh ok`; `kexec_load.ko` sha256 `b1b8a7964a06d7ebcd45170b6565f6d9e348c5fc885eba3ae7fc818f404b1956`; a static ARM `kexec`; `nixos` holds only `new`, and its `cmdline` ends with `init=$top/init`
- **p2:** `CYLON_ROOT`; `toplevel present`; the registration file is non-empty; the host key has mode `600` and its fingerprint reads `root@cylon-link`
- no loop device left

Always clean up, even on failure.

- [ ] **Step 7: Commit**

```bash
just fmt
git add hosts/cylon-link/image.nix hosts/cylon-link/configuration.nix hosts/cylon-link/flash.sh hosts/cylon-link/config-test.nix justfile
git commit -m "feat(cylon-link): flash a prebuilt disk image"
```

---

### Task 7: Install on the Steam Link

Needs the user for the physical steps. Nothing to commit unless troubleshooting changes code.

**Interfaces:**
- Consumes: `just flash-cylon-link` (Task 6).
- Produces: `cylon-link` online on the tailnet, and the findings for the spec's "To verify" list, recorded for Task 9.

- [ ] **Step 1: Ask the user to move the stick**

Ask the user to unplug the Steam Link's power, move the Kingston stick to raider, and say when it is in.

- [ ] **Step 2: Confirm the device with the user, then flash**

```bash
ls -l /dev/disk/by-id/ | grep -i kingston
lsblk -o NAME,SIZE,MODEL,SERIAL,FSTYPE,LABEL "$(readlink -f /dev/disk/by-id/usb-Kingston_DataTraveler_3.0_1C6F654E4168F290E9213192-0:0)"
```

Show the user this output. Say plainly that flashing erases the Debian install on the stick, and get an explicit yes. Then, inside `nix develop`:

```bash
printf 'y\n' | just flash-cylon-link /dev/disk/by-id/usb-Kingston_DataTraveler_3.0_1C6F654E4168F290E9213192-0:0
```

Expected: `Stick written.`, then `Done: …`. The stick is powered off.

- [ ] **Step 3: Ask the user to boot the Steam Link**

Tell the user to put the stick in the Steam Link (the only USB storage attached), connect Ethernet, and plug in the power.

- [ ] **Step 4: Wait for the node, up to 10 minutes**

Watch with the Monitor tool, not a background shell:

```bash
until tailscale status | grep -q '\bcylon-link\b'; do sleep 10; done; tailscale status | grep cylon-link
```

In parallel, check the LAN every minute: `sudo nmap -sn -PR -n 192.168.18.0/24 | grep -i -B2 E0:31:9E:19:06:5C`.

- [ ] **Step 5: Verify the booted system**

```bash
ssh root@cylon-link.bat-boa.ts.net '
  uname -a; cat /proc/cmdline; echo
  systemctl --failed --no-legend
  systemctl status cylon-link-boot-ok --no-pager | head -12
  ls -la /boot/steamlink/nixos
  free -m; df -h / /boot/steamlink
  journalctl -b -p warning --no-pager | head -40'
```

Expected:
- the kernel is `6.18.50`
- the command line ends with `cylon.entry=new`
- no failed units
- `cylon-link-boot-ok` is `active (exited)` and logged "is now the good entry"
- `nixos/` holds `good` and `new`, with no `tried-*` markers

Ask the user to check the Tailscale admin console (Machines): `cylon-link` must not be marked Ephemeral. Record the answer.

If it is ephemeral, stop and tell the user. The host needs a reusable, non-ephemeral key stored as its own secret instead of `tailscale-key`, which is a design change.

- [ ] **Step 6: If the node never appears**

1. **The LAN shows `e0:31:9e:19:06:5c` with port 22 open.** Try `ssh root@<ip>`: NixOS's openssh accepts the fleet root key. Debug from there with `journalctl -b`.
2. **The LAN shows the MAC but NixOS is not reachable.**
   1. Ask the user to power-cycle once. With `tried-new` set and no `good`, `run.sh` leaves the stock firmware running.
   2. Connect with `sshpass -p steamlink123 ssh root@<ip>` (sshpass comes from `nix build --no-link --print-out-paths --inputs-from . nixpkgs#sshpass`).
   3. Change the root password with `passwd`, and give the new one to the user.
   4. Inspect with `mount`, `ls -la /mnt/disk /mnt/disk/nixos`, `dmesg | tail -50`, and `ls /mnt`. This shows where the firmware mounted the stick and whether `run.sh` ran.
3. **The firmware did not mount p1, or did not run `run.sh` from it.** This is the unconfirmed two-partition assumption failing. Stop and report to the user with what `mount` showed. The layout needs revisiting in the spec.
4. **The MAC never appears.** The firmware is not reaching the network at all. Ask the user to check the Ethernet cable and whether the TV shows the Steam Link UI.

- [ ] **Step 7: Record findings**

Write down, for Task 9:
- how long it took from power-on until the node was up
- where the firmware mounted the stick
- the result of the Ephemeral check
- `free -m`
- anything from the troubleshooting path

---

### Task 8: Deploy round trip and fallback test

**Interfaces:**
- Consumes: a running `cylon-link` (Task 7).
- Produces:
  - a committed motd change deployed through `just deploy`
  - a proven fallback path
  - timings for Task 9

- [ ] **Step 1: Deploy a real change**

Add to `hosts/cylon-link/configuration.nix`:

```nix
  users.motd = ''
    cylon-link — Valve Steam Link running NixOS.
    No reboot: kernel changes need `just boot cylon-link` and a power cycle.
  '';
```

```bash
just fmt
git add hosts/cylon-link/configuration.nix
git commit -m "feat(cylon-link): add motd"
time just deploy cylon-link
ssh root@cylon-link.bat-boa.ts.net 'cat /etc/motd; ls -la /boot/steamlink/nixos; cat /boot/steamlink/nixos/new/cmdline'
```

Expected: the deploy succeeds (phase 1 on raider, phase 2 over Tailscale SSH), and `/etc/motd` shows the text. `new/cmdline` names the new generation's `init`. `good` is still the flashed one, and there is no `tried-new`. Record the deploy time.

If phase 2 fails with a Tailscale SSH authorization error, stop and ask the user to allow raider → `cylon-link` as root in the tailnet ACL.

- [ ] **Step 2: Install a deliberately broken generation (never committed)**

In `hosts/cylon-link/hardware.nix`, temporarily add a parameter to the existing list. This nixpkgs uses the systemd initrd by default, so scripted-initrd hooks such as `postDeviceCommands` do not evaluate. Instead, the initrd is told to stop in its emergency target, which waits forever for a console that does not exist:

```nix
  boot.kernelParams = ["console=ttyS0,115200n8" "usbcore.autosuspend=-1" "rd.systemd.unit=emergency.target"];
```

```bash
just boot cylon-link
ssh root@cylon-link.bat-boa.ts.net 'diff /boot/steamlink/nixos/new/cmdline /boot/steamlink/nixos/good/cmdline; ls /boot/steamlink/nixos'
```

Expected: the two `cmdline`s differ, and there are no `tried-*` markers.

- [ ] **Step 3: Power-cycle into the broken generation**

Ask the user to power-cycle the Steam Link. Wait 5 minutes. `cylon-link` must stay offline in `tailscale status`, because the initrd stops in `emergency.target`.

- [ ] **Step 4: Power-cycle into the fallback**

Ask the user to power-cycle again. Wait for `cylon-link` in `tailscale status` (Monitor, up to 10 minutes), then:

```bash
ssh root@cylon-link.bat-boa.ts.net 'grep -o "cylon.entry=[a-z]*" /proc/cmdline; ls /boot/steamlink/nixos; systemctl is-active cylon-link-boot-ok'
```

Expected: `cylon.entry=good`, `tried-new` present, `tried-good` absent, and `active`.

- [ ] **Step 5: Restore and boot the working generation**

```bash
git checkout -- hosts/cylon-link/hardware.nix
git status --short hosts/cylon-link   # expect no output
just boot cylon-link
```

Ask the user to power-cycle once more. After the node returns:

```bash
ssh root@cylon-link.bat-boa.ts.net 'grep -o "cylon.entry=[a-z]*" /proc/cmdline; ls /boot/steamlink/nixos; cat /etc/motd'
```

Expected: `cylon.entry=new`, no `tried-*` markers, and the motd present. The good entry is now this generation.

---

### Task 9: Documentation

**Files:**
- Modify: `CLAUDE.md` ("Available Hosts" list, plus a new section after "Host Tiers")
- Modify: `HARDWARE.md` (new host entry)
- Modify: `docs/superpowers/specs/2026-09-16-cylon-link-design.md` (status and findings)

**Interfaces:**
- Consumes: the findings from Tasks 5, 7 and 8.
- Produces: docs only.

- [ ] **Step 1: `CLAUDE.md`**

Add to "Available Hosts" after `octopi`:

```markdown
- **cylon-link** - Valve Steam Link (armv7l, 512 MB): always-on helper. Cross-compiled on raider, excluded from CI, boots through Valve's firmware and kexec
```

Add a section after "Host Tiers", filling in the measured numbers where marked:

```markdown
### cylon-link (Valve Steam Link)

A 2015 Steam Link running NixOS: one Cortex-A9 core, 512 MB of RAM, a
29 GB USB stick. Design: `docs/superpowers/specs/2026-09-16-cylon-link-design.md`.

**It is cross-compiled on raider and never built by CI.** `nixpkgs.buildPlatform`
is x86_64, so every derivation is an x86_64 job: `just deploy cylon-link` works
unchanged, and `ciExcludedHosts` in `flake-modules/hosts.nix` keeps it out of
`ciMatrix`. nixpkgs caches nothing for armv7l, so a nixpkgs bump rebuilds its
closure on raider (<N> min measured, most of it the kernel). A native build on
basestar is possible but was abandoned after 86 minutes without finishing the
toolchain. The device itself has `max-jobs = 0`.

**There is no reboot.** The mainline kernel cannot restart this SoC. `just deploy`
is fine, but a kernel or initrd change needs `just boot cylon-link` and a power cycle,
and `just reboot cylon-link` hangs the box until someone does that.

**How it boots.** Valve's signed bootloader only loads its own Linux 3.8.13,
but that firmware runs `steamlink/factory_test/run.sh` from a USB stick at
power-on. On `CYLON_BOOT` (p1, ext3, mounted at `/boot/steamlink`) that script
picks a staged generation and kexecs into nixpkgs' kernel, using a prebuilt
`kexec_load.ko` and a static musl `kexec`. NixOS binaries cannot run there:
nixpkgs' glibc needs Linux >= 3.10. NixOS lives on `CYLON_ROOT` (p2).
`boot.loader.external` stages every switch as `nixos/new`, and
`cylon-link-boot-ok.service` promotes it to `nixos/good` once Tailscale is up.
Keep `run.sh` POSIX sh with no externals beyond `sync`, `insmod` and `fts-set`;
`checks.x86_64-linux.cylon-link-boot` tests it.

**When a generation fails.** Each entry is tried once. A new generation that
never reaches Tailscale costs one extra power cycle and the box comes back on
`good`. If `good` fails too, the stock firmware stays up with SSH
(`root`, password <as changed, or Valve's default `steamlink123`>), where the
stick is mounted at <path found in Task 7>. `touch /boot/steamlink/steamlink/rescue`
from NixOS forces that on the next power cycle. Delete the file to go back.

**Reinstall or recover** with `just flash-cylon-link /dev/disk/by-id/usb-…` from
raider. It erases the stick. The SSH host key, and with it the sops identity,
comes from `secrets/sops/cylon-link-hostkey.yaml`, so a reflash keeps
`common.yaml` readable. Tailscale sees a new node.
```

- [ ] **Step 2: `HARDWARE.md`**

Add under "Online Hosts", after basestar:

```markdown
### cylon-link
- **Role**: Always-on helper (Valve Steam Link running NixOS)
- **Architecture**: armv7l (cross-compiled from x86_64)
- **CPU**: Marvell Berlin BG2CD (DE3005), ARM Cortex-A9 - 1 core visible
- **RAM**: 512 MB (498 MiB usable)
- **Disks**:
  - USB 28.8 GB - Kingston DataTraveler 3.0 (`CYLON_BOOT` 1 GiB ext3 + `CYLON_ROOT` ext4)
  - internal 1 GB NAND - unused (no mainline driver)
- **Network**: 100 Mb Ethernet (`pxa168_eth`, MAC e0:31:9e:19:06:5c); Marvell SDIO Wi-Fi/BT unused
- **Note**: No reboot, no video output under the mainline kernel
```

- [ ] **Step 3: Spec**

In `docs/superpowers/specs/2026-09-16-cylon-link-design.md`:
- Change `**Status:**` to `implemented <date>`.
- Under each "To verify during implementation" bullet, append the finding recorded in Tasks 5, 7 and 8, for example "Verified: firmware mounted p1 at /mnt/disk".
  - For the `ghostty.terminfo` bullet, write "Verified: 4.9 KiB, no references; included via `buildPackages`".
  - For the watchdog bullet, write "Not investigated; reboot remains out of scope".
  - For the firmware-update bullet, write "Unchanged; nothing to verify".

- [ ] **Step 4: Commit and hand over**

```bash
git add CLAUDE.md HARDWARE.md docs/superpowers/specs/2026-09-16-cylon-link-design.md
git commit -m "docs(cylon-link): document the Steam Link host"
git log --oneline origin/master..HEAD
```

Ask the user whether to push. Pushing runs CI, which now skips `cylon-link` but builds every other host for the new `self`.
