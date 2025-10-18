# Disko configuration for raider gaming system
# Target disk: XrayDisk 512GB NVMe SSD
{
  disko.devices = {
    disk = {
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
                  "/home" = {
                    mountpoint = "/home";
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
    };
  };
}
