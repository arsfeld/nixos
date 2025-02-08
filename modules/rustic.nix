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
            removeAttrs (builtins.getAttr name config.services.rustic.profiles) ["timerConfig" "environment" "environmentFile"]
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
      environment = mkIf (profile.environment != null) profile.environment;
      path = [pkgs.rclone];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${pkgs.rustic}/bin/rustic -P ${name} backup";
        EnvironmentFile = mkIf (profile.environmentFile != null) profile.environmentFile;
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
    environment.systemPackages = [pkgs.rustic];
    environment.etc = etcConfigs;
    systemd.services = systemdServices;
    systemd.timers = systemdTimers;
  };
}
