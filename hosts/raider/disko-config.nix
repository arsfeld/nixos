# Disko configuration for raider gaming system
# Main disk: XrayDisk 512GB NVMe SSD (system partitions)
# Home disk: Samsung MZ7LN512HAJQ 512GB SATA SSD (/home)
{
  disko.devices = {
    disk = {
      # Main NVMe disk for system partitions
      main = {
        type = "disk";
        device = "/dev/disk/by-id/nvme-XrayDisk_512GB_SSD_AA000000000000000321";
        content = {
          type = "gpt";
          partitions = {
            ESP = {
              priority = 1;
              size = "512M";
              type = "EF00";
              content = {
                type = "filesystem";
                format = "vfat";
                mountpoint = "/boot";
                mountOptions = [
                  "defaults"
                  "umask=0077"
                ];
              };
            };
            root = {
              priority = 3;
              size = "100%";
              content = {
                type = "btrfs";
                extraArgs = ["-f"]; # Force creation
                subvolumes = {
                  "/root" = {
                    mountpoint = "/";
                    mountOptions = ["compress=zstd" "noatime"];
                  };
                  "/nix" = {
                    mountpoint = "/nix";
                    mountOptions = ["compress=zstd" "noatime"];
                  };
                  "/var/log" = {
                    mountpoint = "/var/log";
                    mountOptions = ["compress=zstd" "noatime"];
                  };
                  "/tmp" = {
                    mountpoint = "/tmp";
                    mountOptions = ["noatime"];
                  };
                };
              };
            };
          };
        };
      };

      # Samsung SSD for /home
      home = {
        type = "disk";
        device = "/dev/disk/by-id/ata-SAMSUNG_MZ7LN512HAJQ-000H1_S3TANA0KA01037";
        content = {
          type = "gpt";
          partitions = {
            home = {
              size = "100%";
              content = {
                type = "btrfs";
                extraArgs = ["-f"];
                subvolumes = {
                  "/home" = {
                    mountpoint = "/home";
                    mountOptions = ["compress=zstd" "noatime"];
                  };
                };
              };
            };
          };
        };
      };

      # SOLIDIGM 2TB NVMe for games
      games = {
        type = "disk";
        device = "/dev/disk/by-id/nvme-SOLIDIGM_SSDPFKNU020TZ_PHEH2476001Y2P0C";
        content = {
          type = "gpt";
          partitions = {
            games = {
              size = "100%";
              content = {
                type = "filesystem";
                format = "xfs";
                mountpoint = "/mnt/games";
                mountOptions = [
                  "noatime"
                  "discard"
                  "largeio"
                  "inode64"
                  "x-systemd.nofail"
                ];
              };
            };
          };
        };
      };
    };
  };
}
