{
  config,
  lib,
  pkgs,
  ...
}:
with lib; let
  tomlFormat = pkgs.formats.toml {};

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
                log-file = "/var/log/rustic/${name}.log";
              };
            }
            (removeAttrs (builtins.getAttr name config.services.rustic.profiles) ["timerConfig" "environment" "environmentFile"])
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
      environment = {
        RUSTIC_CACHE_DIR = "/var/cache/rustic";
      } // (if profile.environment == null then {} else profile.environment);
      path = [pkgs.rclone];
      serviceConfig = {
        Type = "oneshot";
        ExecStartPre = "${pkgs.coreutils}/bin/mkdir -p /var/cache/rustic";
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
      ${lib.concatStrings (lib.mapAttrsToList (name: value: 
        "export ${name}=${lib.escapeShellArg value}\n"
      ) (if profile.environment == null then {} else profile.environment))}

      exec ${pkgs.rustic}/bin/rustic -P ${name} "$@"
    ''))
  config.services.rustic.profiles;

in {
  options.services.rustic = {
    enable = mkEnableOption "rustic backup service";

    profiles = mkOption {
      type = types.attrsOf (types.submodule {
        freeformType = types.attrs;
        options = {
          timerConfig = mkOption {
            type = types.nullOr types.attrs;
            default = null;
            description = "Systemd timer configuration for this backup profile";
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
            description = "Environment variables for the backup service";
            example = literalExpression ''
              {
                RUSTIC_PASSWORD = "mysecret";
              }
            '';
          };
          environmentFile = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = "Environment file for the backup service";
            example = "/run/secrets/rustic-env";
          };
        };
      });
      default = {};
      description = "Rustic backup profiles";
    };
  };

  config = mkIf config.services.rustic.enable {
    environment.systemPackages = [pkgs.rustic] ++ (builtins.attrValues profileScripts);
    environment.etc = etcConfigs;
    systemd.services = systemdServices;
    systemd.timers = systemdTimers;
  };
}
