# btrfs/disko-config.nix
{disk ? "/dev/disk/by-id/nvme-INTEL_SSDPEKNW512G8_BTNH00850VCA512A", ...}: {
  disko.devices = {
    disk = {
      main = {
        type = "disk";
        device = "${disk}";
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
                randomEncryption = false;
              };
            };
            root = {
              name = "root";
              end = "-8G";
              content = {
                type = "filesystem";
                format = "bcachefs";
                mountpoint = "/";
                #extraArgs = ["-f"]; # Override existing partition
                mountOptions = ["compression=zstd"];
              };
            };
          };
        };
      };
    };
  };
}
