{
  lib,
  config,
  pkgs,
  nixpkgs,
  modulesPath,
  ...
}: {
  services.grafana = {
    enable = true;
    domain = "grafana.${config.vars.domain}";
    port = 2345;
    addr = "0.0.0.0";
  };

  services.prometheus = {
    enable = true;
    port = 8001;

    exporters = {
      node = {
        enable = true;
        enabledCollectors = ["systemd"];
        port = 8002;
      };
    };

    scrapeConfigs = [
      {
        job_name = "storage";
        static_configs = [
          {
            targets = ["127.0.0.1:${toString config.services.prometheus.exporters.node.port}"];
          }
        ];
      }
    ];
  };

  services.loki = {
    enable = true;
    configFile = ../files/loki-local-config.yaml;
  };

  systemd.services.promtail = {
    description = "Promtail service for Loki";
    wantedBy = ["multi-user.target"];

    serviceConfig = {
      ExecStart = ''
        ${pkgs.grafana-loki}/bin/promtail --config.file ${../files/promtail.yaml}
      '';
    };
  };
}
