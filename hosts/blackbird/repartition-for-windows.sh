#!/usr/bin/env bash
# Repartition blackbird's NVMe for Windows dual-boot.
#
# RUN THIS FROM: a NixOS installer booted via Ventoy USB. NOT from the
# running blackbird system -- the disk must be unmounted.
#
# PREREQUISITE (already done on 2026-05-04 from running NixOS):
#   sudo btrfs filesystem resize 500G /
#
# Final layout:
#   p1  500M  ESP            (untouched -- Windows shares this)
#   p2   16G  swap           (untouched)
#   p3  ~513G  btrfs root    (shrunk from ~915G; FS inside is 500G)
#   p4  ~470G  NTFS "WIN"    (Windows installer target)

set -euo pipefail

DISK=/dev/nvme0n1
ROOT_END=530GiB # new end of p3; leaves ~13 GiB slack above the 500 GiB btrfs FS

if mount | grep -q "${DISK}p"; then
  echo "ERROR: ${DISK} has mounted partitions. Boot the live USB and try again." >&2
  mount | grep "${DISK}p" >&2
  exit 1
fi

echo "=== current layout ==="
lsblk -o NAME,SIZE,FSTYPE,LABEL,PARTLABEL "$DISK"
echo
echo "Plan:"
echo "  1. Shrink ${DISK}p3 so it ends at ${ROOT_END}"
echo "  2. Create ${DISK}p4 (NTFS, label WIN) in the freed tail"
echo
read -rp "Type 'yes' to proceed: " ans
[[ "$ans" == "yes" ]] || { echo "aborted"; exit 1; }

parted -s "$DISK" \
  unit GiB \
  resizepart 3 "$ROOT_END" \
  mkpart windows ntfs "$ROOT_END" 100% \
  set 4 msftdata on

partprobe "$DISK"
mkfs.ntfs -Q -L WIN "${DISK}p4"

echo
echo "=== final layout ==="
lsblk -o NAME,SIZE,FSTYPE,LABEL,PARTLABEL "$DISK"
echo
cat <<'EOF'
Next:
  1. Reboot, boot the Windows ISO from Ventoy.
  2. In the installer, pick the WIN (NTFS) partition. Do NOT reformat the
     small FAT ESP -- Windows will add its EFI files to the existing one.
  3. After Windows install, in elevated cmd:  powercfg /h off
  4. Save the BitLocker recovery key if it auto-enables (TPM-backed).
  5. Back in NixOS, update hosts/blackbird/disko-config.nix to reflect the
     new layout (root size + windows partition) so a future disko reformat
     does not wipe Windows.
EOF
