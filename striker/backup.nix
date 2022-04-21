{
  lib,
  config,
  pkgs,
  nixpkgs,
  modulesPath,
  ...
}: let
  homeDir = "/mnt/data/homes/arosenfeld";
in {
  services.borgbackup.jobs = {
    # for a local backup
    dataBackup = {
      paths = "/var/data";
      repo = "/data/files/Backups/borg";
      compression = "zstd";
      encryption.mode = "none";
      startAt = "daily";
    };
  };

  systemd = {
    /*
     timers.rclone-sync = {
       wantedBy = [ "timers.target" ];
       partOf = [ "rclone-sync.service" ];
       timerConfig.OnCalendar = "daily";
     };
     */
    services.rclone-sync = let
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
