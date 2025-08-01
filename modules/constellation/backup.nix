# Constellation backup module
#
# This module provides automated backup configuration using Rustic (Restic-compatible
# backup tool). It sets up scheduled backups to multiple destinations including
# local S3-compatible storage and cloud providers.
#
# Key features:
# - Automated weekly backups with randomized scheduling to prevent load spikes
# - Multiple backup profiles (cottage S3, iDrive cloud storage)
# - Intelligent exclusion of cache directories and large system paths
# - Encrypted backups using age-encrypted passwords
# - Automatic snapshot initialization
#
# The module backs up critical system directories (/var/lib, /var/data, /home, /root)
# while excluding temporary files, caches, and container storage to optimize
# backup size and performance.
#
# Backup destinations:
# - cottage: MinIO S3-compatible storage on cottage host
# - idrive: Cloud backup to iDrive E2 storage
{
  lib,
  config,
  self,
  ...
}:
with lib; let
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
            "/home"
            "/root"
          ];
          globs = [
            # very large paths
            "!/var/lib/docker"
            "!/var/lib/containers"
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
in {
  options.constellation.backup = {
    enable = mkOption {
      type = types.bool;
      description = ''
        Enable automated backup configuration using Rustic.
        This sets up scheduled backups to multiple destinations with
        intelligent file exclusions and encrypted storage.
      '';
      default = false;
    };
  };

  config = mkIf config.constellation.backup.enable {
    age.secrets."restic-password".file = "${self}/secrets/restic-password.age";
    age.secrets."restic-truenas".file = "${self}/secrets/restic-truenas.age";
    age.secrets."restic-cottage-minio".file = "${self}/secrets/restic-cottage-minio.age";
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
                endpoint = "http://cottage.bat-boa.ts.net:9000";
                region = "auto";
              };
            };
            environmentFile = config.age.secrets."restic-cottage-minio".path;
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
  };
}
