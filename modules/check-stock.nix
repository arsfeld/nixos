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
        description = "URL to monitor for stock";
      };
      timerConfig = mkOption {
        type = types.attrs;
        default = {OnCalendar = "hourly";};
        description = "Systemd timer configuration";
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
    enable = mkEnableOption "Framework stock checker service";

    urls = mkOption {
      type = types.attrsOf (types.submodule urlOpts);
      default = {};
      description = "URLs to monitor for stock availability";
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
