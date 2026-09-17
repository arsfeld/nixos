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
