# Storage root layout — btrfs RAID1 across two Samsung 512G SATA SSDs.
# Migrated from a single Intel NVMe (which had failing endurance).
#
# Two ESPs are kept in sync via boot.loader.systemd-boot.mirroredBoots
# (see configuration.nix). UEFI firmware picks which one to boot; if the
# disk holding the primary ESP dies, the second entry takes over.
#
# Note: for a fresh disko install, the btrfs RAID1 is created on disk-a-root,
# then disk-b-root is added via the postCreateHook.
{...}: {
  disko.devices = {
    disk = {
      ssd-a = {
        type = "disk";
        device = "/dev/disk/by-id/ata-SAMSUNG_MZ7LN512HAJQ-000H1_S3TANA0M602723";
        content = {
          type = "gpt";
          partitions = {
            ESP = {
              size = "1G";
              type = "EF00";
              content = {
                type = "filesystem";
                format = "vfat";
                mountpoint = "/boot";
              };
            };
            swap = {
              size = "16G";
              content = {
                type = "swap";
              };
            };
            root = {
              size = "100%";
              content = {
                type = "btrfs";
                extraArgs = ["-f" "-L" "root"];
                postCreateHook = ''
                  btrfs device add -f /dev/disk/by-partlabel/disk-ssd-b-root /mnt
                  btrfs balance start -mconvert=raid1 -dconvert=raid1 /mnt
                '';
                subvolumes = {
                  "@" = {};
                  "@/root" = {
                    mountpoint = "/";
                    mountOptions = ["compress=zstd" "noatime"];
                  };
                  "@/home" = {
                    mountpoint = "/home-old";
                    mountOptions = ["compress=zstd"];
                  };
                  "@/nix" = {
                    mountpoint = "/nix";
                    mountOptions = ["compress=zstd" "noatime"];
                  };
                  "@/var-lib" = {
                    mountpoint = "/var/lib";
                    mountOptions = ["compress=zstd" "noatime"];
                  };
                  "@/var-log" = {
                    mountpoint = "/var/log";
                    mountOptions = ["compress=zstd" "noatime"];
                  };
                  "@/var-data" = {
                    mountpoint = "/var/data";
                    mountOptions = ["compress=zstd" "noatime"];
                  };
                  "@/var-tmp" = {
                    mountpoint = "/var/tmp";
                    mountOptions = ["compress=zstd" "noatime"];
                  };
                };
              };
            };
          };
        };
      };
      ssd-b = {
        type = "disk";
        device = "/dev/disk/by-id/ata-SAMSUNG_MZ7LN512HAJQ-000H1_S3TANA0M808229";
        content = {
          type = "gpt";
          partitions = {
            ESP = {
              size = "1G";
              type = "EF00";
              content = {
                type = "filesystem";
                format = "vfat";
                mountpoint = "/boot-fallback";
              };
            };
            swap = {
              size = "16G";
              content = {
                type = "swap";
              };
            };
            root = {
              size = "100%";
              # No content: this partition is the second member of the btrfs
              # RAID1 above and is attached via the postCreateHook on ssd-a/root.
            };
          };
        };
      };
    };
  };
}
