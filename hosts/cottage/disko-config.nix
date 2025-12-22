# Disko configuration for cottage
# Boot: btrfs with subvolumes on Samsung SSD
# Storage: bcachefs array will be configured after install (live ISO lacks bcachefs module)
{...}: {
  disko.devices = {
    disk = {
      # Boot disk - Samsung 512GB SSD
      boot = {
        type = "disk";
        device = "/dev/disk/by-id/ata-SAMSUNG_MZ7LN512HMJP-000L1_S2URNX0HC00771";
        content = {
          type = "gpt";
          partitions = {
            ESP = {
              size = "512M";
              type = "EF00";
              content = {
                type = "filesystem";
                format = "vfat";
                mountpoint = "/boot";
                mountOptions = ["umask=0077"];
              };
            };
            root = {
              size = "100%";
              content = {
                type = "btrfs";
                extraArgs = ["-f"];
                subvolumes = {
                  "@" = {
                    mountpoint = "/";
                    mountOptions = ["compress=zstd" "noatime"];
                  };
                  "@home" = {
                    mountpoint = "/home";
                    mountOptions = ["compress=zstd" "noatime"];
                  };
                  "@nix" = {
                    mountpoint = "/nix";
                    mountOptions = ["compress=zstd" "noatime"];
                  };
                  "@var" = {
                    mountpoint = "/var";
                    mountOptions = ["compress=zstd" "noatime"];
                  };
                  "@swap" = {
                    mountpoint = "/.swap";
                    swap.swapfile.size = "8G";
                  };
                };
              };
            };
          };
        };
      };

      # Data disks will be configured after install when bcachefs is available
      # 4x 4TB drives for bcachefs replicas=2 array (~8TB usable)
      # - ata-ST4000VN000-1H4168_Z3051HFQ
      # - ata-ST4000VN008-2DR166_WDH2WDVD
      # - ata-WDC_WD40EFRX-68N32N0_WD-WCC7K7HJ9TV6
      # - ata-ST4000VN000-1H4168_Z304SS33
      # Excluded: ata-ST4000VN008-2DR166_WDH2Y01G (failing - 104 pending sectors)
    };
  };
}
