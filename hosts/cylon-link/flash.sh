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
