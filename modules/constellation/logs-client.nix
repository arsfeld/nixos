# Constellation Logs Client Module
#
# This module configures Promtail to ship systemd journal logs to the
# central Loki instance on the storage host.
#
# Key features:
# - Ships systemd journal logs to central Loki server
# - Labels logs with hostname and systemd unit for easy filtering
# - Filters debug/verbose logs to reduce volume and storage costs
# - Lightweight and minimal resource usage
# - Automatic log retention management by Loki
#
# Logs are shipped to the Loki instance on storage:3030 over the
# Tailscale network for centralized log aggregation and analysis.
{
  pkgs,
  lib,
  config,
  ...
}: {
  options.constellation.logs-client = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Enable Promtail log shipping to central Loki server.
        Systemd journal logs are shipped to the storage host for
        centralized log aggregation and analysis.
      '';
    };

    lokiUrl = lib.mkOption {
      type = lib.types.str;
      default = "http://storage:3030";
      description = "URL of the central Loki server";
    };

    filterDebugLogs = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Filter out debug-level logs to reduce volume";
    };

    maxAge = lib.mkOption {
      type = lib.types.str;
      default = "12h";
      description = "Maximum age of logs to read from journal";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 9080;
      description = "Port for Promtail HTTP server";
    };
  };

  config = lib.mkIf config.constellation.logs-client.enable {
    services.promtail = {
      enable = true;
      configuration = {
        server = {
          http_listen_port = config.constellation.logs-client.port;
          grpc_listen_port = 0;
        };

        positions = {
          filename = "/var/lib/promtail/positions.yaml";
        };

        clients = [
          {
            url = "${config.constellation.logs-client.lokiUrl}/loki/api/v1/push";
            batchwait = "1s";
            batchsize = 1048576; # 1MB
            external_labels = {
              host = config.networking.hostName;
            };
          }
        ];

        scrape_configs = [
          {
            job_name = "journal";
            journal = {
              max_age = config.constellation.logs-client.maxAge;
              labels = {
                job = "systemd-journal";
                host = config.networking.hostName;
              };
            };
            relabel_configs = [
              {
                source_labels = ["__journal__systemd_unit"];
                target_label = "unit";
              }
              {
                source_labels = ["__journal_priority_keyword"];
                target_label = "level";
              }
              {
                source_labels = ["__journal__hostname"];
                target_label = "hostname";
              }
              {
                source_labels = ["__journal_syslog_identifier"];
                target_label = "syslog_identifier";
              }
            ];
            pipeline_stages = lib.optional config.constellation.logs-client.filterDebugLogs {
              drop = {
                source = "level";
                value = "debug";
              };
            };
          }
        ];
      };
    };

    # Ensure Promtail directories exist
    systemd.tmpfiles.rules = [
      "d /var/lib/promtail 0755 promtail promtail -"
    ];
  };
}
