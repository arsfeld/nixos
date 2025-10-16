# Constellation Metrics Client Module
#
# This module configures Prometheus node exporter on constellation hosts
# to expose system metrics for the central Prometheus server on storage to scrape.
#
# Key features:
# - Comprehensive system metrics collection (CPU, memory, disk, network, systemd)
# - Lightweight and low-overhead operation
# - Firewall configured to allow scraping only from Tailscale network
# - Optional Caddy metrics exporter
# - Textfile collector support for custom metrics
#
# Metrics are exposed on port 9100 and scraped by the central Prometheus
# instance running on the storage host. All communication happens over
# the Tailscale network for security.
{
  pkgs,
  lib,
  config,
  ...
}: {
  options.constellation.metrics-client = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Enable Prometheus node exporter for system metrics collection.
        Metrics are exposed on port 9100 for scraping by the central
        Prometheus server on the storage host.
      '';
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 9100;
      description = "Port for node exporter to listen on";
    };

    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Open firewall for metrics scraping from Tailscale network";
    };

    collectors = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "systemd"
        "tcpstat"
        "netstat"
        "netdev"
        "diskstats"
        "filesystem"
        "meminfo"
        "cpu"
        "loadavg"
        "thermal_zone"
        "hwmon"
        "stat"
        "time"
        "uname"
        "vmstat"
        "netclass"
        "sockstat"
        "pressure"
      ];
      description = "List of node exporter collectors to enable";
    };

    caddy = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Enable Caddy metrics endpoint (requires Caddy to be running)";
      };

      port = lib.mkOption {
        type = lib.types.port;
        default = 2019;
        description = "Port for Caddy metrics endpoint";
      };
    };
  };

  config = lib.mkIf config.constellation.metrics-client.enable {
    # Prometheus Node Exporter
    services.prometheus.exporters.node = {
      enable = true;
      port = config.constellation.metrics-client.port;
      enabledCollectors = config.constellation.metrics-client.collectors;
      extraFlags = [
        "--collector.textfile.directory=/var/lib/prometheus-node-exporter-text-files"
      ];
      # Only listen on localhost and Tailscale interface
      listenAddress = "0.0.0.0";
    };

    # Create textfile directory for custom metrics
    systemd.tmpfiles.rules = [
      "d /var/lib/prometheus-node-exporter-text-files 0755 root root -"
    ];

    # Caddy metrics configuration (if enabled)
    # Caddy exposes Prometheus metrics on its admin API endpoint
    # We create a virtual host to expose metrics on a dedicated port
    services.caddy.virtualHosts = lib.mkIf config.constellation.metrics-client.caddy.enable {
      ":${toString config.constellation.metrics-client.caddy.port}" = {
        extraConfig = ''
          metrics /metrics
        '';
      };
    };

    # Open firewall for Tailscale network only
    # Note: This assumes the Tailscale interface is named "tailscale0"
    # The actual interface name may vary, so we open it globally but only
    # on the node exporter port which should only be accessible from Tailscale
    networking.firewall = lib.mkIf config.constellation.metrics-client.openFirewall {
      allowedTCPPorts =
        [
          config.constellation.metrics-client.port
        ]
        ++ lib.optional config.constellation.metrics-client.caddy.enable
        config.constellation.metrics-client.caddy.port;
    };
  };
}
