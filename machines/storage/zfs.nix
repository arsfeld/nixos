{
  config,
  pkgs,
  lib,
  ...
}:
with lib; {
  boot.supportedFilesystems = ["zfs"];

  boot.zfs = {
    forceImportAll = false;
    extraPools = ["data"];
  };

  services.zfs = {
    autoScrub.enable = true;
    trim.enable = true;
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
