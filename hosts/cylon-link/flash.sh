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
