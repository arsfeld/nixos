# Constellation backup module
#
# This module provides automated backup configuration using Rustic (Restic-compatible
# backup tool). It sets up scheduled backups to the storage host's restic REST server.
#
# Key features:
# - Automated weekly backups with randomized scheduling to prevent load spikes
# - Intelligent exclusion of cache directories and large system paths
# - Encrypted backups using age-encrypted passwords
# - Automatic snapshot initialization
#
# The module backs up critical system directories (/var/lib, /var/data, /home, /root)
# while excluding temporary files, caches, and container storage to optimize
# backup size and performance.
#
# Backup destination:
# - storage: Restic REST server running on storage.bat-boa.ts.net:8000
{
  lib,
  config,
  self,
  ...
}:
with lib; let
  useSops = config.constellation.sops.enable;
  resticPasswordPath =
    if useSops
    then config.sops.secrets."restic-password".path
    else config.age.secrets."restic-password".path;
  opts = {
    repository = {
      password-file = resticPasswordPath;
    };
    backup = {
      init = true;
      snapshots = [
        {
          sources = [
            "/var/lib"
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

  config = mkIf config.constellation.backup.enable (lib.mkMerge [
    (lib.mkIf useSops {
      sops.secrets."restic-password" = {
        sopsFile = config.constellation.sops.commonSopsFile;
      };
    })
    (lib.mkIf (!useSops) {
      age.secrets."restic-password".file = "${self}/secrets/restic-password.age";
    })
    {
      services.rustic = {
        enable = true;
        profiles = {
          storage =
            recursiveUpdate
            opts
            {
              repository = {
                repository = "rest:http://storage.bat-boa.ts.net:8000/";
                password-file = resticPasswordPath;
                init = true;
              };
            };
        };
      };
    }
  ]);
}
