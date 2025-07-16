{
  config,
  lib,
  pkgs,
  ...
}: {
  disko.devices = {
    disk = {
      nvme0n1 = {
        device = "/dev/nvme0n1";
        type = "disk";
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
                mountOptions = [
                  "defaults"
                ];
              };
            };
            root = {
              size = "100%";
              content = {
                type = "filesystem";
                format = "f2fs";
                mountpoint = "/";
                mountOptions = [
                  "compress_algorithm=zstd"
                  "compress_extension=*"
                  "noatime"
                  "background_gc=on"
                  "discard"
                ];
              };
            };
          };
        };
      };
    };
  };
}
