#!/usr/bin/env bash
set -euo pipefail

# Migration script: Move /home from NVMe btrfs to Samsung SSD btrfs
# This script must be run as root on the raider host

echo "=== Home Migration to Samsung SSD ==="
echo "This will partition /dev/disk/by-id/ata-SAMSUNG_MZ7LN512HAJQ-000H1_S3TANA0KA01037"
echo "and migrate /home data using btrfs send/receive"
echo ""

# Safety check
if [[ "$(hostname)" != "raider" ]]; then
    echo "ERROR: This script must be run on raider host"
    exit 1
fi

if [[ "$EUID" -ne 0 ]]; then
    echo "ERROR: This script must be run as root"
    exit 1
fi

# Variables
SAMSUNG_DISK="/dev/disk/by-id/ata-SAMSUNG_MZ7LN512HAJQ-000H1_S3TANA0KA01037"
NVME_DISK="/dev/disk/by-id/nvme-XrayDisk_512GB_SSD_AA000000000000000321"
NEW_HOME_MOUNT="/mnt/new-home"
OLD_HOME_MOUNT="/mnt/old-home"

echo "Step 1: Check current /home usage"
df -h /home
du -sh /home

echo ""
echo "Step 2: Partition and format Samsung SSD"
echo "Creating GPT partition table..."

# Clear any existing partition table
sgdisk --zap-all "$SAMSUNG_DISK"
sgdisk --clear "$SAMSUNG_DISK"

# Create single partition using all space
sgdisk --align-end \
    --new=1:0:-0 \
    --partition-guid="1:R" \
    --change-name="1:disk-home-home" \
    --typecode=1:8300 \
    "$SAMSUNG_DISK"

# Refresh partition table
partprobe "$SAMSUNG_DISK"
udevadm settle --timeout 30

echo "Step 3: Create btrfs filesystem on Samsung SSD"
mkfs.btrfs -f /dev/disk/by-partlabel/disk-home-home

# Mount the new filesystem
mkdir -p "$NEW_HOME_MOUNT"
mount /dev/disk/by-partlabel/disk-home-home "$NEW_HOME_MOUNT"

echo "Step 4: Create /home subvolume on new disk"
btrfs subvolume create "$NEW_HOME_MOUNT/home"

echo "Step 5: Create read-only snapshot of current /home"
# Mount the NVMe btrfs root
mkdir -p "$OLD_HOME_MOUNT"
mount -o subvol=/ "${NVME_DISK}-part2" "$OLD_HOME_MOUNT"

# Create snapshot directory if it doesn't exist
mkdir -p "$OLD_HOME_MOUNT/.snapshots"

# Create read-only snapshot
SNAPSHOT_NAME="home-migration-$(date +%Y%m%d-%H%M%S)"
btrfs subvolume snapshot -r "$OLD_HOME_MOUNT/home" "$OLD_HOME_MOUNT/.snapshots/$SNAPSHOT_NAME"

echo "Step 6: Transfer data using btrfs send/receive"
echo "This may take a while depending on /home size..."
btrfs send "$OLD_HOME_MOUNT/.snapshots/$SNAPSHOT_NAME" | \
    btrfs receive "$NEW_HOME_MOUNT/"

# Delete the initial empty home subvolume
btrfs subvolume delete "$NEW_HOME_MOUNT/home"

# Create a writable snapshot from the received subvolume
btrfs subvolume snapshot "$NEW_HOME_MOUNT/$SNAPSHOT_NAME" "$NEW_HOME_MOUNT/home"

# Delete the read-only received subvolume
btrfs subvolume delete "$NEW_HOME_MOUNT/$SNAPSHOT_NAME"

echo "Step 7: Verify data transfer"
echo "Old /home size:"
du -sh "$OLD_HOME_MOUNT/home"
echo "New /home size:"
du -sh "$NEW_HOME_MOUNT/home"

echo ""
echo "Step 8: Verify file count"
echo "Old /home files:"
find "$OLD_HOME_MOUNT/home" -type f | wc -l
echo "New /home files:"
find "$NEW_HOME_MOUNT/home" -type f | wc -l

echo ""
echo "Step 9: List new /home contents"
ls -la "$NEW_HOME_MOUNT/home/"

echo ""
echo "Step 10: Cleanup - unmount temporary mounts"
umount "$NEW_HOME_MOUNT"
umount "$OLD_HOME_MOUNT"
rmdir "$NEW_HOME_MOUNT" "$OLD_HOME_MOUNT"

echo ""
echo "=== Migration Complete ==="
echo "The Samsung SSD is now partitioned and contains all /home data."
echo ""
echo "Next steps:"
echo "1. Deploy new configuration: just boot raider"
echo "2. Reboot and verify /home mounts correctly"
echo "3. After confirming everything works, delete old /home subvolume and snapshot"
echo ""
echo "Snapshot preserved at: ${NVME_DISK}-part2/.snapshots/$SNAPSHOT_NAME"
