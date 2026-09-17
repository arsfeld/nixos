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
