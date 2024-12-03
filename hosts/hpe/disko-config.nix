# btrfs/disko-config.nix
{lib, ...}: {
  disko.devices = {
    disk = {
      main = {
        type = "disk";
        device = "/dev/sda";
        content = {
          type = "gpt";
          partitions = {
            ESP = {
              size = "500M";
              type = "EF00";
              content = {
                type = "filesystem";
                format = "vfat";
                mountpoint = "/boot";
              };
            };
            swap = {
              size = "100%";
              content = {
                type = "swap";
              };
            };
            root = {
              end = "-32G";
              content = {
                type = "btrfs";
                extraArgs = ["-f"]; # Override existing partition
                subvolumes = {
                  "@" = {};
                  "@/root" = {
                    mountpoint = "/";
                    mountOptions = ["compress=zstd" "noatime"];
                  };
                  "@/home" = {
                    mountpoint = "/home";
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
    };
  };
}
