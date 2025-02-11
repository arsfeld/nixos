{
  lib,
  config,
  pkgs,
  self,
  ...
}: let
  opts = {
    repository = {
      password-file = config.age.secrets."restic-password".path;
    };
    backup = {
      init = true;
      snapshots = [
        {
          sources = [
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
            "!/mnt"

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
    age.secrets."restic-password".file = "${self}/secrets/restic-password.age";
    age.secrets."restic-truenas".file = "${self}/secrets/restic-truenas.age";
    age.secrets."idrive-env".file = "${self}/secrets/idrive-env.age";
    age.secrets."restic-rclone-idrive".file = "${self}/secrets/rclone-idrive.age";

    services.rustic = {
      enable = true;
      profiles = {
        cottage =
          recursiveUpdate
          opts
          {
            repository = {
              repository = "opendal:s3";
              options = {
                bucket = "restic";
                endpoint = "http://cottage:9000";
                region = "auto";
              };
            };
            environmentFile = config.age.secrets.restic-truenas.path;
          };

        idrive =
          recursiveUpdate
          opts
          {
            environment = {
              RCLONE_CONFIG = config.age.secrets."restic-rclone-idrive".path;
            };
            repository = {
              repository = "rclone:idrive:arosenfeld";
              password-file = config.age.secrets."restic-password".path;
            };
          };
      };
    };
  }
