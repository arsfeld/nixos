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
}:
with lib; let
  cfg = config.services.check-stock;

  urlOpts = {
    name,
    config,
    ...
  }: {
    options = {
      name = mkOption {
        type = types.str;
        default = name;
        description = "Name of the stock check service";
      };
      url = mkOption {
        type = types.str;
        description = "URL to monitor for stock availability";
      };
      timerConfig = mkOption {
        type = types.attrs;
        default = {OnCalendar = "hourly";};
        description = ''
          Systemd timer configuration for scheduling stock checks.
          See {manpage}`systemd.timer(5)` for available options.
        '';
        example = literalExpression ''
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
    enable = mkEnableOption "stock availability monitoring service";

    urls = mkOption {
      type = types.attrsOf (types.submodule urlOpts);
      default = {};
      description = ''
        URLs to monitor for stock availability. Each URL will have its own
        systemd service and timer generated automatically.
      '';
      example = literalExpression ''
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

  config = mkIf cfg.enable {
    environment.systemPackages = [
      pkgs.check-stock
      (pkgs.writeShellApplication {
        name = "check-all-stock";
        text = ''
          ${pkgs.check-stock}/bin/check-stock ${lib.concatMapStringsSep " " (item: item.url) (attrValues cfg.urls)}
        '';
      })
    ];

    systemd.services = lib.mkMerge (map mkStockService (attrValues cfg.urls));
    systemd.timers = lib.mkMerge (map mkStockTimer (attrValues cfg.urls));
  };
}
