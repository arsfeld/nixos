{
  config,
  pkgs,
  lib,
  ...
}: let
  rustic = pkgs.writeShellScriptBin "restic" ''
    for v in `printenv | grep RESTIC_`
    do
        export RUSTIC_''${v#"RESTIC_"}
    done
    exec ${pkgs.rustic-rs}/bin/rustic "$@"
  '';
  glob = [
    # very large paths
    "!/var/lib/docker"
    "!/var/lib/systemd"
    "!/var/lib/libvirt"

    "!**/.cache"
    "!**/.nix-profile"
  ];
in
  with lib; {
    age.secrets."rclone-idrive".file = ../../secrets/rclone-idrive.age;
    age.secrets."rclone-idrive".mode = "444";

    age.secrets."restic-password".file = ../../secrets/restic-password.age;
    age.secrets."restic-password".mode = "444";

    services.restic.backups = {
      nas = {
        paths = ["/var/data"];
        repository = "/mnt/data/backups/restic";
        passwordFile = "/etc/secrets/restic";
        timerConfig = {
          OnCalendar = "daily";
        };
      };

      idrive = {
        package = rustic;
        repository = "rclone:idrive:arosenfeld";
        extraBackupArgs = [
          "--one-file-system"
          "--glob-file=${pkgs.writeText "glob-file" (concatStringsSep "\n" glob)}"
          "--progress-interval=1s"
        ];
        paths = [
          "/mnt/data/homes"
          "/var/lib"
          "/var/data"
          "/root"
        ];
        rcloneConfigFile = config.age.secrets."rclone-idrive".path;
        passwordFile = config.age.secrets."restic-password".path;
        timerConfig = {
          OnCalendar = "weekly";
        };
      };

      local = {
        package = rustic;
        repository = "/mnt/backup/restic";
        initialize = true;
        extraBackupArgs = [
          "--one-file-system"
          "--glob-file=${pkgs.writeText "glob-file" (concatStringsSep "\n" glob)}"
          "--progress-interval=1s"
        ];
        paths = [
          "/mnt/data/homes"
          "/var/lib"
          "/var/data"
          "/root"
        ];
        passwordFile = config.age.secrets."restic-password".path;
        timerConfig = {
          OnCalendar = "daily";
        };
      };
    };
  }
