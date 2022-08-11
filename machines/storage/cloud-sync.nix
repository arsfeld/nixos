{
  lib,
  config,
  pkgs,
  nixpkgs,
  modulesPath,
  ...
}: let
  homeDir = "/mnt/data/homes/arosenfeld/Cloud";
in {
  systemd = {
    timers.cloud-sync = {
      wantedBy = ["timers.target"];
      partOf = ["cloud-sync.service"];
      timerConfig.OnCalendar = "daily";
    };
    services.cloud-sync = let
      rcloneOptions = "--fast-list --stats-one-line --verbose";
    in {
      serviceConfig.Type = "oneshot";
      serviceConfig.User = "arosenfeld";
      script = ''
        ${pkgs.rclone}/bin/rclone sync ${rcloneOptions} dropbox: ${homeDir}/Dropbox
        ${pkgs.rclone}/bin/rclone sync ${rcloneOptions} gdrive: ${homeDir}/Google\ Drive
        ${pkgs.rclone}/bin/rclone sync ${rcloneOptions} onedrive: ${homeDir}/One\ Drive
        ${pkgs.rclone}/bin/rclone sync ${rcloneOptions} box: ${homeDir}/Box
      '';
    };
  };
}
