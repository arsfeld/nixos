{
  config,
  lib,
  pkgs,
  ...
}: let
  # Get network configuration
  netConfig = config.router.network;
  alertingConfig = config.router.alerting;
in {
  options.router.alerting = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable Prometheus alerting with Alertmanager";
    };

    emailConfig = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = config.constellation.email.enable;
        description = "Enable email notifications (uses constellation email config)";
      };
    };

    webhookUrl = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Webhook URL for notifications (Discord, Slack, etc)";
    };

    ntfyUrl = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "ntfy.sh topic URL for push notifications";
    };

    thresholds = {
      diskUsagePercent = lib.mkOption {
        type = lib.types.int;
        default = 80;
        description = "Disk usage percentage threshold";
      };

      temperatureCelsius = lib.mkOption {
        type = lib.types.int;
        default = 70;
        description = "Temperature threshold in Celsius";
      };

      bandwidthMbps = lib.mkOption {
        type = lib.types.int;
        default = 2000;
        description = "Per-client bandwidth threshold in Mbps";
      };

      cpuUsagePercent = lib.mkOption {
        type = lib.types.int;
        default = 90;
        description = "CPU usage percentage threshold";
      };

      memoryUsagePercent = lib.mkOption {
        type = lib.types.int;
        default = 85;
        description = "Memory usage percentage threshold";
      };
    };
  };

  config = lib.mkIf alertingConfig.enable {
    # Prometheus Alertmanager
    services.prometheus.alertmanager = {
      enable = true;
      listenAddress = "0.0.0.0";
      port = 9093;

      configuration = {
        global = lib.optionalAttrs alertingConfig.emailConfig.enable {
          smtp_from = config.constellation.email.fromEmail;
          smtp_smarthost = "smtp.purelymail.com:587";
          smtp_auth_username = config.constellation.email.toEmail;
          smtp_auth_password_file = config.age.secrets.smtp_password.path;
          smtp_require_tls = true;
        };

        route = {
          group_by = ["alertname" "cluster" "service"];
          group_wait = "10s";
          group_interval = "10s";
          repeat_interval = "1h";
          receiver = "default";

          routes = [
            {
              # Critical alerts - immediate notification
              match = {severity = "critical";};
              repeat_interval = "15m";
              receiver = "critical";
            }
            {
              # New client alerts - grouped notifications
              match = {alertname = "NewClientDetected";};
              group_wait = "30s";
              group_interval = "5m";
              repeat_interval = "12h";
              receiver = "info";
            }
          ];
        };

        receivers = [
          ({
              name = "default";
            }
            // lib.optionalAttrs alertingConfig.emailConfig.enable {
              email_configs = [
                {
                  to = config.constellation.email.toEmail;
                }
              ];
            }
            // lib.optionalAttrs (alertingConfig.webhookUrl != null) {
              webhook_configs = [
                {
                  url = alertingConfig.webhookUrl;
                }
              ];
            })

          ({
              name = "critical";
            }
            // lib.optionalAttrs alertingConfig.emailConfig.enable {
              email_configs = [
                {
                  to = config.constellation.email.toEmail;
                }
              ];
            }
            // lib.optionalAttrs (alertingConfig.webhookUrl != null || alertingConfig.ntfyUrl != null) {
              webhook_configs = lib.concatLists [
                (lib.optional (alertingConfig.webhookUrl != null) {
                  url = alertingConfig.webhookUrl;
                })
                (lib.optional (alertingConfig.ntfyUrl != null) {
                  url = "http://localhost:9095";
                  send_resolved = true;
                })
              ];
            })

          ({
              name = "info";
            }
            // lib.optionalAttrs (alertingConfig.webhookUrl != null || alertingConfig.ntfyUrl != null) {
              webhook_configs = lib.concatLists [
                (lib.optional (alertingConfig.webhookUrl != null) {
                  url = alertingConfig.webhookUrl;
                })
                (lib.optional (alertingConfig.ntfyUrl != null) {
                  url = "http://localhost:9095";
                  send_resolved = false;
                })
              ];
            })
        ];

        inhibit_rules = [
          {
            source_match = {severity = "critical";};
            target_match = {severity = "warning";};
            equal = ["alertname" "instance"];
          }
        ];
      };
    };

    # VictoriaMetrics vmalert service for alert rules
    systemd.services.vmalert = {
      description = "VictoriaMetrics vmalert";
      after = ["network.target" "victoriametrics.service"];
      wantedBy = ["multi-user.target"];
      serviceConfig = {
        Type = "simple";
        ExecStart = let
          alertRulesFile = pkgs.writeText "vmalert-rules.yml" ''
            groups:
              - name: router_alerts
                interval: 30s
                rules:
                  # Disk space alerts
                  - alert: DiskSpaceLow
                    expr: 100 - (node_filesystem_avail_bytes{mountpoint="/"} * 100 / node_filesystem_size_bytes{mountpoint="/"}) > ${toString alertingConfig.thresholds.diskUsagePercent}
                    for: 5m
                    labels:
                      severity: warning
                    annotations:
                      summary: "Disk space is running low"
                      description: "Disk usage is at {{ $value | printf \"%.1f\" }}% on {{ $labels.instance }}"

                  - alert: DiskSpaceCritical
                    expr: 100 - (node_filesystem_avail_bytes{mountpoint="/"} * 100 / node_filesystem_size_bytes{mountpoint="/"}) > 90
                    for: 2m
                    labels:
                      severity: critical
                    annotations:
                      summary: "Disk space critically low"
                      description: "Disk usage is at {{ $value | printf \"%.1f\" }}% on {{ $labels.instance }}"

                  # Temperature alerts
                  - alert: HighTemperature
                    expr: node_hwmon_temp_celsius > ${toString alertingConfig.thresholds.temperatureCelsius}
                    for: 3m
                    labels:
                      severity: warning
                    annotations:
                      summary: "High temperature detected"
                      description: "Temperature is {{ $value }}°C on {{ $labels.chip }} sensor {{ $labels.sensor }}"

                  - alert: CriticalTemperature
                    expr: node_hwmon_temp_celsius > 80
                    for: 1m
                    labels:
                      severity: critical
                    annotations:
                      summary: "Critical temperature detected"
                      description: "Temperature is {{ $value }}°C on {{ $labels.chip }} sensor {{ $labels.sensor }}"

                  # Bandwidth alerts
                  - alert: HighBandwidthUsage
                    expr: (rate(client_traffic_bytes_total[5m]) * 8 / 1000000) > ${toString alertingConfig.thresholds.bandwidthMbps}
                    for: 5m
                    labels:
                      severity: warning
                    annotations:
                      summary: "High bandwidth usage detected"
                      description: "Client {{ $labels.ip }} ({{ $labels.name }}) is using {{ $value | printf \"%.1f\" }} Mbps {{ $labels.direction }}"

                  # New client detection
                  - alert: NewClientDetected
                    expr: increase(client_status[5m]) > 0 and client_status == 1
                    labels:
                      severity: info
                    annotations:
                      summary: "New client joined the network"
                      description: "New client {{ $labels.ip }} ({{ $labels.name }}) has joined the network"

                  # CPU usage alerts
                  - alert: HighCPUUsage
                    expr: 100 - (avg(rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100) > ${toString alertingConfig.thresholds.cpuUsagePercent}
                    for: 5m
                    labels:
                      severity: warning
                    annotations:
                      summary: "High CPU usage"
                      description: "CPU usage is at {{ $value | printf \"%.1f\" }}%"

                  # Memory usage alerts
                  - alert: HighMemoryUsage
                    expr: 100 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes * 100) > ${toString alertingConfig.thresholds.memoryUsagePercent}
                    for: 5m
                    labels:
                      severity: warning
                    annotations:
                      summary: "High memory usage"
                      description: "Memory usage is at {{ $value | printf \"%.1f\" }}%"

                  # Network interface down
                  - alert: NetworkInterfaceDown
                    expr: node_network_up{device=~"enp2s0"} == 0
                    for: 1m
                    labels:
                      severity: critical
                    annotations:
                      summary: "Network interface down"
                      description: "Network interface {{ $labels.device }} is down"

                  # Service health checks
                  - alert: ServiceDown
                    expr: up{job=~"blocky|grafana|victoriametrics"} == 0
                    for: 2m
                    labels:
                      severity: critical
                    annotations:
                      summary: "Service is down"
                      description: "Service {{ $labels.job }} is down"

                  # QoS/Traffic shaping alerts
                  - alert: HighPacketDrops
                    expr: rate(cake_stats{metric="drops"}[5m]) > 100
                    for: 5m
                    labels:
                      severity: warning
                    annotations:
                      summary: "High packet drop rate"
                      description: "Device {{ $labels.device }} is dropping {{ $value | printf \"%.1f\" }} packets/sec"

                  # DNS issues
                  - alert: HighDNSFailureRate
                    expr: rate(blocky_query_total{reason="blocked"}[5m]) / rate(blocky_query_total[5m]) > 0.5
                    for: 5m
                    labels:
                      severity: warning
                    annotations:
                      summary: "High DNS block rate"
                      description: "DNS is blocking {{ $value | printf \"%.1f\" }}% of queries"
          '';
        in
          "${pkgs.victoriametrics}/bin/vmalert -datasource.url=http://localhost:8428 -notifier.url=http://localhost:9093 -rule=${alertRulesFile} -httpListenAddr=:8880";
        Restart = "always";
        RestartSec = "10s";
      };
    };

    # Update Grafana to use Alertmanager as a datasource
    services.grafana.provision.datasources.settings.datasources = lib.mkAfter [
      {
        name = "Alertmanager";
        type = "alertmanager";
        url = "http://localhost:9093";
        isDefault = false;
      }
    ];

    # Open firewall port for Alertmanager (if needed for external access)
    # networking.firewall.allowedTCPPorts = [ 9093 ];
  };
}
