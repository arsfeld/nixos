{
  config,
  lib,
  pkgs,
  ...
}: let
  netConfig = config.router.network;
  routerIp = "${netConfig.prefix}.1";
in {
  # Caddy reverse proxy
  services.caddy = {
    enable = true;
    
    # Global options
    globalConfig = ''
      # Allow internal networks only
      @internal {
        remote_ip ${netConfig.prefix}.0/${toString netConfig.cidr}
        remote_ip 127.0.0.1
      }
    '';

    # Virtual host configuration
    virtualHosts = {
      "http://${routerIp}" = {
        extraConfig = ''
          # Restrict all routes to internal network only
          @blocked not remote_ip ${netConfig.prefix}.0/${toString netConfig.cidr} 127.0.0.1
          respond @blocked "Access denied" 403

          # Grafana - Monitoring dashboards
          handle_path /grafana* {
            reverse_proxy localhost:3000
          }

          # Prometheus - Metrics database
          handle_path /prometheus* {
            reverse_proxy localhost:9090
          }

          # Alertmanager - Alert management
          handle_path /alertmanager* {
            reverse_proxy localhost:9093
          }

          # Loki - Log aggregation
          handle_path /loki* {
            reverse_proxy localhost:3100
          }

          # Promtail - Log shipper status
          handle_path /promtail* {
            reverse_proxy localhost:9080
          }

          # Blocky DNS API
          handle_path /blocky* {
            reverse_proxy localhost:4000
          }

          # Default landing page
          handle / {
            respond "Router Services" 200
          }

          # Service status page
          handle /status {
            respond "
              <html>
              <head><title>Router Services</title></head>
              <body>
                <h1>Router Services</h1>
                <ul>
                  <li><a href='/grafana'>Grafana</a> - Monitoring Dashboards</li>
                  <li><a href='/prometheus'>Prometheus</a> - Metrics Database</li>
                  <li><a href='/alertmanager'>Alertmanager</a> - Alert Management</li>
                  <li><a href='/loki'>Loki</a> - Log Aggregation</li>
                  <li><a href='/promtail'>Promtail</a> - Log Shipper</li>
                  <li><a href='/blocky'>Blocky</a> - DNS Server API</li>
                </ul>
              </body>
              </html>
            " 200
          }
        '';
      };

      # Alternative access via hostname
      "http://router.${netConfig.domain}" = {
        extraConfig = ''
          # Redirect to IP-based access
          redir http://${routerIp}{uri} permanent
        '';
      };

      # Tailscale hostname access
      "http://router.bat-boa.ts.net" = {
        extraConfig = ''
          # Allow Tailscale network
          @blocked not remote_ip 100.64.0.0/10 ${netConfig.prefix}.0/${toString netConfig.cidr} 127.0.0.1
          respond @blocked "Access denied" 403

          # Same routing as main host
          handle_path /grafana* {
            reverse_proxy localhost:3000
          }

          handle_path /prometheus* {
            reverse_proxy localhost:9090
          }

          handle_path /alertmanager* {
            reverse_proxy localhost:9093
          }

          handle_path /loki* {
            reverse_proxy localhost:3100
          }

          handle_path /promtail* {
            reverse_proxy localhost:9080
          }

          handle_path /blocky* {
            reverse_proxy localhost:4000
          }

          handle / {
            respond "Router Services" 200
          }

          handle /status {
            respond "
              <html>
              <head><title>Router Services</title></head>
              <body>
                <h1>Router Services</h1>
                <ul>
                  <li><a href='/grafana'>Grafana</a> - Monitoring Dashboards</li>
                  <li><a href='/prometheus'>Prometheus</a> - Metrics Database</li>
                  <li><a href='/alertmanager'>Alertmanager</a> - Alert Management</li>
                  <li><a href='/loki'>Loki</a> - Log Aggregation</li>
                  <li><a href='/promtail'>Promtail</a> - Log Shipper</li>
                  <li><a href='/blocky'>Blocky</a> - DNS Server API</li>
                </ul>
              </body>
              </html>
            " 200
          }
        '';
      };
    };
  };

  # Update Grafana configuration to work behind reverse proxy
  services.grafana.settings = lib.mkIf config.services.grafana.enable {
    server = {
      root_url = "http://${routerIp}/grafana/";
      serve_from_sub_path = true;
    };
  };

  # Update Prometheus configuration for reverse proxy
  services.prometheus = lib.mkIf config.services.prometheus.enable {
    webExternalUrl = "http://${routerIp}/prometheus/";
    extraFlags = [
      "--web.route-prefix=/prometheus"
    ];
  };

  # Update Alertmanager configuration for reverse proxy
  services.prometheus.alertmanager = lib.mkIf config.services.prometheus.alertmanager.enable {
    webExternalUrl = "http://${routerIp}/alertmanager/";
    extraFlags = [
      "--web.route-prefix=/alertmanager"
    ];
  };

  # Open firewall ports for Caddy (only on LAN interface)
  networking.firewall.interfaces.br-lan = {
    allowedTCPPorts = [
      80  # HTTP
    ];
  };
}