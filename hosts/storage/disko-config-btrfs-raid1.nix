# BTRFS RAID1 Configuration for /mnt/storage
#
# ⚠️  THIS CONFIGURATION IS DISABLED AND FOR PLANNING ONLY ⚠️
# DO NOT ENABLE OR DEPLOY WITHOUT BACKING UP DATA FIRST
#
# This configuration transforms the storage array from bcachefs to btrfs RAID1.
# It will DESTROY all existing data on the specified disks.
#
# APPROACH: Due to disko's limited native support for multi-device btrfs RAID,
# this configuration uses a hybrid approach:
# 1. Disko creates initial single-device btrfs filesystem on first disk
# 2. Post-install script adds remaining disks and converts to RAID1
#
# Storage disks (6 total, mixed sizes - ~42TB raw, ~21TB usable):
# - sda: 476.9G Samsung SSD (wwn-0x5002538d00c64e98)
# - sdb: 476.9G Samsung SSD (wwn-0x5002538d098031e0)
# - sdc: 7.3T WD HDD (wwn-0x5000cca0c2da52b1)
# - sdd: 12.7T Seagate HDD (wwn-0x5000c500e86c43b1)
# - sde: 12.7T Seagate HDD (wwn-0x5000c500e987a4cc)
# - sdf: 7.3T WD HDD (wwn-0x5000cca0becf6150)
{
  config,
  lib,
  pkgs,
  ...
}:
# DISABLED: Remove these comment markers to enable
/*
{
  # Import this file in configuration.nix by uncommenting the import line
  # imports = [ ./disko-config-btrfs-raid1.nix ];

  disko.devices = {
    disk = {
      # PRIMARY DISK: Create initial btrfs filesystem here
      # Using largest disk (Seagate 14TB) as primary
      storage-primary = {
        type = "disk";
        device = "/dev/disk/by-id/wwn-0x5000c500e86c43b1";
        content = {
          type = "gpt";
          partitions = {
            storage = {
              size = "100%";
              content = {
                type = "btrfs";
                extraArgs = [
                  "-f"  # Force overwrite
                  "-L" "storage-array"  # Filesystem label
                  # Start with single device, convert to RAID1 post-install
                  # Using dup for metadata initially (default for single device)
                ];
                # Subvolumes for organization
                subvolumes = {
                  # Main data subvolume
                  "/data" = {
                    mountpoint = "/mnt/storage";
                    mountOptions = [
                      "compress=zstd:3"  # Compression level 3 (balanced speed/ratio)
                      "noatime"          # Don't update access times (performance)
                      "space_cache=v2"   # Use modern space cache
                      "autodefrag"       # Auto-defragment over time
                    ];
                  };
                  # Homes subvolume (for bind mount to /home)
                  "/homes" = {
                    mountpoint = "/mnt/storage/homes";
                    mountOptions = [
                      "compress=zstd:3"
                      "noatime"
                      "space_cache=v2"
                    ];
                  };
                  # Snapshots subvolume for backups
                  "/.snapshots" = {
                    mountpoint = "/mnt/storage/.snapshots";
                    mountOptions = [
                      "compress=zstd:3"
                      "noatime"
                      "space_cache=v2"
                    ];
                  };
                };
              };
            };
          };
        };
      };
    };
  };

  # Bind mount /home to /mnt/storage/homes
  fileSystems."/home" = {
    device = "/mnt/storage/homes";
    fsType = "none";
    options = [ "bind" ];
    depends = [ "/mnt/storage" ];
  };

  # Systemd service to complete RAID1 setup post-boot
  # This adds remaining disks and converts to RAID1
  systemd.services.btrfs-raid-setup = {
    description = "Complete btrfs RAID1 array setup";
    wantedBy = [ "multi-user.target" ];
    after = [ "mnt-storage.mount" ];
    requires = [ "mnt-storage.mount" ];

    # Run once, then disable itself
    unitConfig = {
      ConditionPathExists = "!/var/lib/btrfs-raid-setup-complete";
    };

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };

    script = ''
      set -euo pipefail

      echo "Starting btrfs RAID1 conversion..."

      # Additional disks to add to the array
      DISKS=(
        "/dev/disk/by-id/wwn-0x5000c500e987a4cc"  # Seagate 14TB #2
        "/dev/disk/by-id/wwn-0x5000cca0c2da52b1"  # WD 8TB #1
        "/dev/disk/by-id/wwn-0x5000cca0becf6150"  # WD 8TB #2
        "/dev/disk/by-id/wwn-0x5002538d00c64e98"  # Samsung SSD #1
        "/dev/disk/by-id/wwn-0x5002538d098031e0"  # Samsung SSD #2
      )

      # Add each disk to the array
      for disk in "''${DISKS[@]}"; do
        echo "Adding $disk to array..."
        ${pkgs.btrfs-progs}/bin/btrfs device add -f "$disk" /mnt/storage
      done

      echo "Converting to RAID1 (data and metadata)..."
      # This may take hours depending on data size
      ${pkgs.btrfs-progs}/bin/btrfs balance start -dconvert=raid1 -mconvert=raid1 /mnt/storage

      # Mark setup as complete
      touch /var/lib/btrfs-raid-setup-complete

      echo "RAID1 conversion complete!"
      echo "Run 'btrfs filesystem show /mnt/storage' to verify"
    '';
  };
}
*/
# Placeholder to make the file valid Nix when disabled
{}
