# Stock availability monitoring service
#
# This module provides a service for monitoring product availability on websites.
# It's designed to check stock status of items (e.g., Framework laptop components)
# by periodically fetching URLs and checking for availability indicators.
#
# Features:
# - Multiple URL monitoring with individual timer configurations
# - Configurable check intervals per URL
# - Automatic systemd service and timer generation
# - Convenience command to check all configured URLs at once
#
# Example usage:
#   services.check-stock = {
#     enable = true;
#     urls = {
#       framework-battery = {
#         url = "https://frame.work/products/battery";
#         timerConfig = { OnCalendar = "hourly"; };
#       };
#     };
#   };
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.check-stock;

  urlOpts = {
    name,
    config,
    ...
  }: {
    options = {
      name = lib.mkOption {
        type = lib.types.str;
        default = name;
        description = "Name of the stock check service";
      };
      url = lib.mkOption {
        type = lib.types.str;
        description = "URL to monitor for stock availability";
      };
      timerConfig = lib.mkOption {
        type = lib.types.attrs;
        default = {OnCalendar = "hourly";};
        description = ''
          Systemd timer configuration for scheduling stock checks.
          See {manpage}`systemd.timer(5)` for available options.
        '';
        example = lib.literalExpression ''
          {
            OnCalendar = "daily";
            Persistent = true;
          }
        '';
      };
    };
  };

  # Generate systemd services and timers from the URLs
  mkStockService = {
    name,
    url,
    ...
  }: {
    "check-stock-${name}" = {
      serviceConfig = {
        ExecStart = ["${pkgs.check-stock}/bin/check-stock ${url}"];
        # Publisher credentials for authenticated ntfy.arsfeld.one publishes.
        # File is populated by sops-nix at activation time on hosts that
        # declare sops.secrets."ntfy-publisher-env"; systemd reads the env
        # file as PID 1 (root), so the child process UID is irrelevant.
        EnvironmentFile = "/run/secrets/ntfy-publisher-env";
      };
    };
  };

  mkStockTimer = {
    name,
    timerConfig,
    ...
  }: {
    "check-stock-${name}" = {
      wantedBy = ["timers.target"];
      timerConfig = timerConfig;
    };
  };
in {
  options.services.check-stock = {
    enable = lib.mkEnableOption "stock availability monitoring service";

    urls = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule urlOpts);
      default = {};
      description = ''
        URLs to monitor for stock availability. Each URL will have its own
        systemd service and timer generated automatically.
      '';
      example = lib.literalExpression ''
        {
          framework-battery = {
            url = "https://frame.work/products/battery";
            timerConfig = { OnCalendar = "hourly"; };
          };
          framework-mainboard = {
            url = "https://frame.work/products/mainboard";
            timerConfig = { OnCalendar = "*:0/30"; };  # Every 30 minutes
          };
        }
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [
      pkgs.check-stock
      (pkgs.writeShellApplication {
        name = "check-all-stock";
        text = ''
          ${pkgs.check-stock}/bin/check-stock ${lib.concatMapStringsSep " " (item: item.url) (lib.attrValues cfg.urls)}
        '';
      })
    ];

    systemd.services = lib.mkMerge (map mkStockService (lib.attrValues cfg.urls));
    systemd.timers = lib.mkMerge (map mkStockTimer (lib.attrValues cfg.urls));
  };
}
