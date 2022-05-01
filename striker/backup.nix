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
      repo = "/mnt/data/files/Backups/borg";
      compression = "zstd";
      encryption.mode = "none";
      startAt = "daily";
    };

    "borgbase" = {
      paths = [
        "/var/lib"
        "/var/data"
        "/srv"
        "/home"
        "/root"
      ];
      exclude = [
        # very large paths
        "/var/lib/docker"
        "/var/lib/systemd"
        "/var/lib/libvirt"
        
        "'**/.cache'"
        "'**/.nix-profile'"
      ];
      repo = "u2ru7hl3@u2ru7hl3.repo.borgbase.com:repo";
      encryption = {
        mode = "repokey-blake2";
        passCommand = "cat /root/borgbackup/passphrase";
      };
      extraCreateArgs = "--progress --verbose --stats";
      environment.BORG_RSH = "ssh -i /root/borgbackup/ssh_key";
      compression = "auto,zstd";
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
