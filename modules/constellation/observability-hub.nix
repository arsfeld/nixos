# Constellation Observability Hub Module
#
# This module creates a central observability hub that runs on the storage host.
# It consolidates metrics and logs from all constellation hosts and provides
# a unified Grafana interface for monitoring and analysis.
#
# Components:
# - Prometheus: Metrics collection and storage with auto-discovery
# - Loki: Log aggregation from all constellation hosts
# - Grafana: Unified visualization and dashboards
# - Alertmanager: Alert routing and notifications
#
# The hub automatically scrapes all constellation hosts that have
# metrics-client enabled and collects logs from all hosts with
# logs-client enabled. It also supports federation with the router's
# VictoriaMetrics instance for network-wide observability.
{
  pkgs,
  lib,
  config,
  ...
}: let
  cfg = config.constellation.observability-hub;
in {
  options.constellation.observability-hub = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Enable the central observability hub.
        This should only be enabled on the storage host.
      '';
    };

    prometheus = {
      port = lib.mkOption {
        type = lib.types.port;
        default = 3020;
        description = "Prometheus HTTP port";
      };

      retention = lib.mkOption {
        type = lib.types.str;
        default = "30d";
        description = "Prometheus data retention period";
      };

      scrapeInterval = lib.mkOption {
        type = lib.types.str;
        default = "30s";
        description = "Default scrape interval for metrics";
      };

      scrapeTargets = lib.mkOption {
        type = lib.types.listOf (lib.types.submodule {
          options = {
            job_name = lib.mkOption {
              type = lib.types.str;
              description = "Job name for this scrape target";
            };
            targets = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              description = "List of target addresses (host:port)";
            };
            labels = lib.mkOption {
              type = lib.types.attrsOf lib.types.str;
              default = {};
              description = "Additional labels for this target";
            };
          };
        });
        default = [];
        description = "Additional scrape targets beyond constellation hosts";
      };
    };

    loki = {
      port = lib.mkOption {
        type = lib.types.port;
        default = 3030;
        description = "Loki HTTP port";
      };

      retention = lib.mkOption {
        type = lib.types.str;
        default = "14d";
        description = "Loki log retention period (in hours, e.g., 336h for 14 days)";
      };
    };

    grafana = {
      port = lib.mkOption {
        type = lib.types.port;
        default = 3010;
        description = "Grafana HTTP port";
      };

      enableAuth = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Enable Tailscale OAuth proxy authentication";
      };
    };

    alerting = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Enable Alertmanager for alert routing";
      };

      port = lib.mkOption {
        type = lib.types.port;
        default = 9093;
        description = "Alertmanager port";
      };

      ntfyUrl = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "ntfy.sh topic URL for push notifications";
      };
    };

    constellationHosts = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "storage:9100"
        "cloud:9100"
        "r2s:9100"
        "raspi3:9100"
        "core:9100"
        "hpe:9100"
        "g14:9100"
        "raider:9100"
        "striker:9100"
      ];
      description = "List of constellation hosts to scrape for node metrics";
    };
  };

  config = lib.mkIf cfg.enable {
    # Prometheus - Metrics collection and storage
    services.prometheus = {
      enable = true;
      port = cfg.prometheus.port;
      retentionTime = cfg.prometheus.retention;
      globalConfig = {
        scrape_interval = cfg.prometheus.scrapeInterval;
        evaluation_interval = cfg.prometheus.scrapeInterval;
      };

      # Local node exporter
      exporters.node = {
        enable = true;
        port = 3021;
        enabledCollectors = ["systemd"];
      };

      scrapeConfigs =
        [
          # Scrape local node exporter
          {
            job_name = "local-node";
            static_configs = [
              {
                targets = ["127.0.0.1:3021"];
                labels = {
                  host = "storage";
                  role = "hub";
                };
              }
            ];
          }

          # Scrape all constellation hosts
          {
            job_name = "constellation-nodes";
            static_configs = [
              {
                targets = cfg.constellationHosts;
              }
            ];
            relabel_configs = [
              {
                source_labels = ["__address__"];
                regex = "([^:]+):.*";
                target_label = "host";
                replacement = "$1";
              }
            ];
          }

          # Router federation (pull VictoriaMetrics metrics)
          {
            job_name = "router-federation";
            honor_labels = true;
            metrics_path = "/api/v1/export";
            params = {
              match = ["{job=~\".+\"}"];
            };
            static_configs = [
              {
                targets = ["router:8428"];
              }
            ];
          }

          # Caddy metrics from hosts running Caddy
          {
            job_name = "caddy";
            metrics_path = "/metrics";
            static_configs = [
              {
                targets = [
                  "storage:2019"
                  "cloud:2019"
                ];
              }
            ];
            relabel_configs = [
              {
                source_labels = ["__address__"];
                regex = "([^:]+):.*";
                target_label = "host";
                replacement = "$1";
              }
            ];
          }
        ]
        ++ (map (target: {
            job_name = target.job_name;
            static_configs = [
              {
                targets = target.targets;
                labels = target.labels;
              }
            ];
          })
          cfg.prometheus.scrapeTargets);

      # Alertmanager configuration
      alertmanagers = lib.mkIf cfg.alerting.enable [
        {
          static_configs = [
            {
              targets = ["localhost:${toString cfg.alerting.port}"];
            }
          ];
        }
      ];

      # Alert rules
      rules = lib.mkIf cfg.alerting.enable [
        ''
          groups:
            - name: constellation_alerts
              interval: 30s
              rules:
                # Host availability
                - alert: HostDown
                  expr: up{job="constellation-nodes"} == 0
                  for: 5m
                  labels:
                    severity: critical
                  annotations:
                    summary: "Host is down"
                    description: "Host {{ $labels.host }} has been down for more than 5 minutes"

                # Disk space alerts
                - alert: DiskSpaceWarning
                  expr: 100 - ((node_filesystem_avail_bytes{fstype!~"tmpfs|ramfs"} * 100) / node_filesystem_size_bytes{fstype!~"tmpfs|ramfs"}) > 80
                  for: 5m
                  labels:
                    severity: warning
                  annotations:
                    summary: "Disk space running low"
                    description: "Disk usage on {{ $labels.host }}:{{ $labels.mountpoint }} is at {{ $value | printf \"%.1f\" }}%"

                - alert: DiskSpaceCritical
                  expr: 100 - ((node_filesystem_avail_bytes{fstype!~"tmpfs|ramfs"} * 100) / node_filesystem_size_bytes{fstype!~"tmpfs|ramfs"}) > 90
                  for: 2m
                  labels:
                    severity: critical
                  annotations:
                    summary: "Disk space critically low"
                    description: "Disk usage on {{ $labels.host }}:{{ $labels.mountpoint }} is at {{ $value | printf \"%.1f\" }}%"

                # Memory alerts
                - alert: MemoryWarning
                  expr: 100 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes * 100) > 85
                  for: 5m
                  labels:
                    severity: warning
                  annotations:
                    summary: "High memory usage"
                    description: "Memory usage on {{ $labels.host }} is at {{ $value | printf \"%.1f\" }}%"

                - alert: MemoryCritical
                  expr: 100 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes * 100) > 95
                  for: 2m
                  labels:
                    severity: critical
                  annotations:
                    summary: "Critical memory usage"
                    description: "Memory usage on {{ $labels.host }} is at {{ $value | printf \"%.1f\" }}%"

                # CPU alerts
                - alert: HighCPUUsage
                  expr: 100 - (avg by (host) (rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100) > 90
                  for: 10m
                  labels:
                    severity: warning
                  annotations:
                    summary: "High CPU usage"
                    description: "CPU usage on {{ $labels.host }} is at {{ $value | printf \"%.1f\" }}%"

                - alert: CriticalCPUUsage
                  expr: 100 - (avg by (host) (rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100) > 95
                  for: 5m
                  labels:
                    severity: critical
                  annotations:
                    summary: "Critical CPU usage"
                    description: "CPU usage on {{ $labels.host }} is at {{ $value | printf \"%.1f\" }}%"

                # Filesystem read-only
                - alert: FilesystemReadOnly
                  expr: node_filesystem_readonly{fstype!~"tmpfs|ramfs"} == 1
                  for: 1m
                  labels:
                    severity: critical
                  annotations:
                    summary: "Filesystem is read-only"
                    description: "Filesystem {{ $labels.mountpoint }} on {{ $labels.host }} is in read-only mode"

                # Systemd service failures
                - alert: SystemdServiceFailed
                  expr: node_systemd_unit_state{state="failed"} == 1
                  for: 2m
                  labels:
                    severity: warning
                  annotations:
                    summary: "Systemd service failed"
                    description: "Service {{ $labels.name }} on {{ $labels.host }} is in failed state"

                # Temperature alerts
                - alert: HighTemperature
                  expr: node_hwmon_temp_celsius > 70
                  for: 5m
                  labels:
                    severity: warning
                  annotations:
                    summary: "High temperature detected"
                    description: "Temperature on {{ $labels.host }} sensor {{ $labels.sensor }} is {{ $value | printf \"%.1f\" }}°C"

                - alert: CriticalTemperature
                  expr: node_hwmon_temp_celsius > 80
                  for: 1m
                  labels:
                    severity: critical
                  annotations:
                    summary: "Critical temperature detected"
                    description: "Temperature on {{ $labels.host }} sensor {{ $labels.sensor }} is {{ $value | printf \"%.1f\" }}°C"

                # Caddy alerts (if metrics available)
                - alert: CaddyHighErrorRate
                  expr: (sum by (host) (rate(caddy_http_requests_total{code=~"5.."}[5m])) / sum by (host) (rate(caddy_http_requests_total[5m]))) > 0.05
                  for: 5m
                  labels:
                    severity: warning
                  annotations:
                    summary: "High HTTP error rate on Caddy"
                    description: "Caddy on {{ $labels.host }} has {{ $value | printf \"%.2f\" }}% error rate"

                - alert: CaddyDown
                  expr: up{job="caddy"} == 0
                  for: 2m
                  labels:
                    severity: critical
                  annotations:
                    summary: "Caddy is down"
                    description: "Caddy on {{ $labels.host }} is not responding"
        ''
      ];
    };

    # Loki - Log aggregation
    services.loki = {
      enable = true;
      configuration = {
        auth_enabled = false;

        server = {
          http_listen_port = cfg.loki.port;
          grpc_listen_port = 9096;
          log_level = "warn";
        };

        common = {
          ring = {
            instance_addr = "127.0.0.1";
            kvstore.store = "inmemory";
          };
          replication_factor = 1;
          path_prefix = "/var/lib/loki";
        };

        schema_config = {
          configs = [
            {
              from = "2024-01-01";
              store = "tsdb";
              object_store = "filesystem";
              schema = "v13";
              index = {
                prefix = "index_";
                period = "24h";
              };
            }
          ];
        };

        storage_config = {
          filesystem = {
            directory = "/var/lib/loki/chunks";
          };
        };

        limits_config = {
          retention_period = cfg.loki.retention;
          reject_old_samples = true;
          reject_old_samples_max_age = "168h";
        };

        compactor = {
          working_directory = "/var/lib/loki/compactor";
          retention_enabled = true;
          retention_delete_delay = "2h";
          compaction_interval = "10m";
        };
      };
    };

    # Grafana - Visualization and dashboards
    services.grafana = {
      enable = true;

      settings = {
        server = {
          protocol = "http";
          http_addr = "0.0.0.0";
          http_port = cfg.grafana.port;
        };

        analytics.reporting_enabled = false;

        users = {
          allow_sign_up = false;
          auto_assign_org = true;
          auto_assign_org_role = "Editor";
        };

        "auth.proxy" = lib.mkIf cfg.grafana.enableAuth {
          enabled = true;
          header_name = "X-Tailscale-User";
          header_property = "username";
          auto_sign_up = true;
          sync_ttl = 0;
          whitelist = "127.0.0.1";
          headers = [
            "Email:X-Tailscale-User-LoginName"
            "Name:X-Tailscale-User-DisplayName"
          ];
          enable_login_token = true;
        };
      };

      provision = {
        enable = true;

        datasources.settings = {
          apiVersion = 1;
          datasources = [
            {
              name = "Prometheus";
              type = "prometheus";
              access = "proxy";
              url = "http://127.0.0.1:${toString cfg.prometheus.port}";
              isDefault = true;
              jsonData = {
                timeInterval = cfg.prometheus.scrapeInterval;
              };
            }
            {
              name = "Loki";
              type = "loki";
              access = "proxy";
              url = "http://127.0.0.1:${toString cfg.loki.port}";
              jsonData = {
                maxLines = 1000;
              };
            }
            {
              name = "Alertmanager";
              type = "alertmanager";
              access = "proxy";
              url = "http://127.0.0.1:${toString cfg.alerting.port}";
              jsonData = {
                implementation = "prometheus";
              };
            }
          ];
        };

        dashboards.settings.providers = [
          {
            name = "Constellation Dashboards";
            folder = "Constellation";
            type = "file";
            options.path = "${./dashboards}";
          }
        ];
      };
    };

    # Alertmanager - Alert routing and notifications
    services.prometheus.alertmanager = lib.mkIf cfg.alerting.enable {
      enable = true;
      port = cfg.alerting.port;
      listenAddress = "127.0.0.1";

      configuration = {
        global = {
          resolve_timeout = "5m";
        };

        route = {
          group_by = ["alertname" "host" "severity"];
          group_wait = "10s";
          group_interval = "10s";
          repeat_interval = "1h";
          receiver = "default";

          routes = [
            {
              match = {severity = "critical";};
              repeat_interval = "15m";
              receiver = "critical";
            }
            {
              match = {severity = "warning";};
              repeat_interval = "1h";
              receiver = "warning";
            }
          ];
        };

        receivers =
          [
            {
              name = "default";
            }
            {
              name = "critical";
            }
            {
              name = "warning";
            }
          ]
          ++ lib.optional (cfg.alerting.ntfyUrl != null) {
            name = "ntfy";
            webhook_configs = [
              {
                url = cfg.alerting.ntfyUrl;
                send_resolved = true;
              }
            ];
          };

        inhibit_rules = [
          {
            source_match = {severity = "critical";};
            target_match = {severity = "warning";};
            equal = ["alertname" "host"];
          }
        ];
      };
    };

    # Create required directories
    systemd.tmpfiles.rules = [
      "d /var/lib/loki 0755 loki loki -"
      "d /var/lib/loki/chunks 0755 loki loki -"
      "d /var/lib/loki/compactor 0755 loki loki -"
    ];

    # Open firewall for internal access (Tailscale network)
    networking.firewall.allowedTCPPorts = [
      cfg.prometheus.port
      cfg.loki.port
      cfg.grafana.port
    ];
  };
}
