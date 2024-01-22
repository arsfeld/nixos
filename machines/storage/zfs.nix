{
  config,
  pkgs,
  lib,
  ...
}:
with lib; {
  boot.supportedFilesystems = ["zfs"];

  networking.hostId = "86f58bee";
  boot.loader = {
    efi.efiSysMountPoint = "/boot/efi";
    efi.canTouchEfiVariables = false;
    generationsDir.copyKernels = true;
    grub = {
      efiInstallAsRemovable = true;
      enable = true;
      copyKernels = true;
      efiSupport = true;
      zfsSupport = true;
      devices = [
        "/dev/disk/by-id/nvme-INTEL_SSDPEKNW512G8_BTNH00850VCA512A"
      ];
    };
  };

  services.zfs = {
    autoScrub.enable = true;
    trim.enable = true;
    zed.enableMail = true;
  };

  services.sanoid = {
    enable = true;

    datasets = {
      "data/homes" = {
        yearly = 5;
        monthly = 24;
      };
      "data/files" = {
        yearly = 5;
        monthly = 24;
      };
    };
  };

  services.znapzend = {
    enable = false;
    pure = true;

    zetup = {
      "data" = {
        # Make snapshots of tank/home every hour, keep those for 1 day,
        # keep every days snapshot for 1 month, etc.
        plan = "1d=>1h,1m=>1d,1y=>1m";
        recursive = true;
        mbuffer = {
          enable = true;
          port = 17777;
        };
        destinations.local = {
          presend = "zpool import -Nf backup";
          dataset = "backup/data";
        };
      };
    };
  };
}
