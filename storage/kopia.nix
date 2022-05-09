{
  lib,
  config,
  pkgs,
  nixpkgs,
  modulesPath,
  ...
}: let
  backupDir = "/home";
in {
  systemd = {
    timers.kopia-backup = {
      enable = false;
      wantedBy = ["timers.target"];
      partOf = ["kopia-backup.service"];
      timerConfig.OnCalendar = "daily";
    };
    services.kopia-backup = let
      kopiaOptions = "--progress";
    in {
      serviceConfig.Type = "oneshot";
      serviceConfig.User = "arosenfeld";
      script = ''
        ${pkgs.kopia}/bin/kopia snapshot create ${kopiaOptions} ${backupDir}
      '';
    };
  };
}
