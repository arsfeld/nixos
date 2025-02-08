{
  lib,
  config,
  pkgs,
  self,
  ...
}: let
  opts = {
    backup = {
      init = true;
      snapshots = [
        {
          sources = [
            "/"
            "/var/lib"
            "/var/data"
            "/mnt/data/files/Immich"
            "/home"
            "/root"
          ];
          globs = [
            # very large paths
            "!/var/lib/docker"
            "!/var/lib/systemd"
            "!/var/lib/libvirt"
            "!/var/lib/lxcfs"
            "!/var/cache"
            "!/nix"

            "!**/.cache"
            "!**/.nix-profile"
          ];
          exclude-if-present = [".nobackup" "CACHEDIR.TAG"];
        }
      ];
    };
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

    services.rustic = {
      enable = true;
      profiles = {
        cottage =
          opts
          // {
            repository = {
              repository = "opendal:s3";
              options = {
                bucket = "restic";
                endpoint = "http://cottage:9000";
              };
              password-file = config.age.secrets."restic-password".path;
            };
            environmentFile = config.age.secrets.restic-truenas.path;
          };

        idrive =
          opts
          // {
            environment = {
              RCLONE_CONFIG = config.age.secrets."restic-rclone-idrive".path;
            };
            repository = {
              repository = "opendal:s3";
              password-file = config.age.secrets."restic-password".path;
            };
          };
      };
    };
  }
