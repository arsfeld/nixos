# Rustic backup service module
#
# This module provides a declarative interface for configuring Rustic, a fast,
# encrypted, and deduplicated backup tool compatible with restic repositories.
#
# Features:
# - Multiple backup profiles with independent configurations
# - Automatic systemd service and timer generation
# - Environment variable and secrets file support
# - TOML configuration generation
# - Per-profile shell scripts for manual execution
# - Centralized logging and caching
# - Nice and IO scheduling for background operation
#
# Example usage:
#   services.rustic = {
#     enable = true;
#     profiles = {
#       home = {
#         repository = "/backup/home";
#         backup.sources = ["/home"];  # Simple string format (automatically converted)
#         keep = { daily = 7; weekly = 4; monthly = 12; };
#         timerConfig = { OnCalendar = "daily"; };
#         environmentFile = "/run/secrets/rustic-home";
#       };
#     };
#   };
{
  config,
  lib,
  pkgs,
  ...
}:
with lib; let
  tomlFormat = pkgs.formats.toml {};

  logDir = config.services.rustic.logDir;
  cacheDir = config.services.rustic.cacheDir;

  # No need to normalize sources - rustic expects a simple array of strings
  normalizeProfile = profile: profile;

  # Create the etc configurations
  etcConfigs = builtins.foldl' (
    acc: name:
      acc
      // {
        "rustic/${name}.toml" = {
          source = tomlFormat.generate "${name}.toml" (
            recursiveUpdate
            {
              global = {
                log-file = "${logDir}/${name}.log";
              };
            }
            (normalizeProfile (removeAttrs (builtins.getAttr name config.services.rustic.profiles) ["timerConfig" "environment" "environmentFile"]))
          );
        };
      }
  ) {} (builtins.attrNames config.services.rustic.profiles);

  # Create the systemd services and timers
  systemdServices = mapAttrs' (name: profile:
    nameValuePair
    "rustic-${name}"
    {
      description = "Rustic backup service for ${name}";
      environment =
        {
          RUSTIC_CACHE_DIR = cacheDir;
        }
        // (
          if profile.environment == null
          then {}
          else profile.environment
        );
      path = [pkgs.rclone];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${pkgs.rustic}/bin/rustic -P ${name} backup";
        EnvironmentFile = mkIf (profile.environmentFile != null) profile.environmentFile;
        Nice = 10;
        IOSchedulingClass = "best-effort";
        IOSchedulingPriority = 7;
      };
    })
  config.services.rustic.profiles;

  # Create systemd timers for profiles that specify timerConfig
  systemdTimers = mapAttrs' (name: profile:
    nameValuePair
    "rustic-${name}"
    (mkIf (profile.timerConfig != null) {
      description = "Timer for Rustic backup service ${name}";
      wantedBy = ["timers.target"];
      timerConfig = profile.timerConfig;
    }))
  config.services.rustic.profiles;

  # Create shell scripts for each profile
  profileScripts = mapAttrs' (name: profile:
    nameValuePair
    "rustic-${name}"
    (pkgs.writeShellScriptBin "rustic-${name}" ''
      #!${pkgs.bash}/bin/bash

      export RUSTIC_CACHE_DIR="/var/cache/rustic"

      # Load environment file if specified
      if [ -n "${toString profile.environmentFile}" ]; then
        set -a
        source "${toString profile.environmentFile}"
        set +a
      fi

      # Load environment variables if specified
      ${lib.concatStrings (lib.mapAttrsToList (
          name: value: "export ${name}=${lib.escapeShellArg value}\n"
        ) (
          if profile.environment == null
          then {}
          else profile.environment
        ))}

      exec ${pkgs.rustic}/bin/rustic -P ${name} "$@"
    ''))
  config.services.rustic.profiles;
in {
  options.services.rustic = {
    enable = mkEnableOption "Rustic backup service";

    logDir = mkOption {
      type = types.str;
      default = "/var/log/rustic";
      description = ''
        Directory where Rustic will store log files.
        One log file will be created per backup profile.
      '';
    };

    cacheDir = mkOption {
      type = types.str;
      default = "/var/cache/rustic";
      description = ''
        Directory where Rustic will store cache files for improved performance.
        This cache is shared across all backup profiles.
      '';
    };

    profiles = mkOption {
      type = types.attrsOf (types.submodule {
        freeformType = types.attrs;
        options = {
          timerConfig = mkOption {
            type = types.nullOr types.attrs;
            default = null;
            description = ''
              Systemd timer configuration for automatic backup scheduling.
              If null, the backup must be triggered manually.
              See {manpage}`systemd.timer(5)` for available options.
            '';
            example = literalExpression ''
              {
                OnCalendar = "daily";
                RandomizedDelaySec = "1h";
              }
            '';
          };
          environment = mkOption {
            type = types.nullOr (types.attrsOf types.str);
            default = null;
            description = ''
              Environment variables to set for this backup profile.
              Useful for passing repository passwords and cloud credentials.
              For sensitive data, prefer using environmentFile instead.
            '';
            example = literalExpression ''
              {
                RUSTIC_PASSWORD = "mysecret";
              }
            '';
          };
          environmentFile = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = ''
              Path to a file containing environment variables for this backup profile.
              The file should contain KEY=value pairs, one per line.
              This is the recommended way to pass sensitive data like passwords.
            '';
            example = "/run/secrets/rustic-env";
          };
        };
      });
      default = {};
      description = ''
        Attribute set of Rustic backup profiles. Each profile generates:
        - A systemd service (rustic-<name>)
        - An optional systemd timer for automatic backups
        - A TOML configuration file in /etc/rustic/
        - A shell script for manual execution

        Profile attributes are passed directly to the Rustic TOML configuration,
        except for timerConfig, environment, and environmentFile which control
        the systemd integration.
      '';
    };
  };

  config = mkIf config.services.rustic.enable {
    environment.systemPackages = [pkgs.rustic] ++ (builtins.attrValues profileScripts);
    environment.etc = etcConfigs;
    systemd.services = systemdServices;
    systemd.timers = systemdTimers;
    systemd.tmpfiles.rules = [
      "d ${logDir} 0755 root root -"
      "d ${cacheDir} 0755 root root -"
    ];
  };
}
