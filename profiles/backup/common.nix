{
  lib,
  config,
  pkgs,
  self,
  ...
}: let
  opts = {
    paths = [
      "/var/lib"
      "/var/data"
      "/mnt/data/files/Immich"
      "/home"
      "/root"
    ];
    exclude = [
      # very large paths
      "/var/lib/docker"
      "/var/lib/systemd"
      "/var/lib/libvirt"

      "**/.cache"
      "**/.nix-profile"
    ];
    passwordFile = config.age.secrets."restic-password".path;
    timerConfig = {
      OnCalendar = "weekly";
      RandomizedDelaySec = "5h";
    };
  };
in
  with lib; {
    age.secrets."restic-rclone-idrive".file = ../../secrets/rclone-idrive.age;
    age.secrets."restic-rclone-idrive".mode = "444";

    age.secrets."restic-password".file = ../../secrets/restic-password.age;
    age.secrets."restic-password".mode = "444";

    age.secrets."restic-truenas".file = "${self}/secrets/restic-truenas.age";

    services.restic.backups = {
      cottage =
        opts
        // {
          initialize = true;
          repository = "s3:http://cottage:9000/restic";
          environmentFile = config.age.secrets.restic-truenas.path;
        };

      idrive =
        opts
        // {
          rcloneConfigFile = config.age.secrets."restic-rclone-idrive".path;
          repository = "rclone:idrive:arosenfeld";
        };
    };
  }
