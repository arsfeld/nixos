{
  config,
  lib,
  pkgs,
  ...
}: let
  netConfig = config.router.network;
  routerIp = "${netConfig.prefix}.1";
in {
  # Dashboard template file
  environment.etc."caddy/dashboard.html".source = ./dashboard.html;

  # Caddy reverse proxy
  services.caddy = {
    enable = true;

    # Virtual host configuration
    virtualHosts = {
      "http://${routerIp}" = {
        extraConfig = ''
          # Restrict all routes to internal network only
          @blocked not remote_ip ${netConfig.prefix}.0/${toString netConfig.cidr} 127.0.0.1
          respond @blocked "Access denied" 403

          # Grafana - Monitoring dashboards
          handle /grafana* {
            reverse_proxy localhost:3000
          }

          # Prometheus - Metrics database
          handle /prometheus* {
            reverse_proxy localhost:9090
          }

          # Alertmanager - Alert management
          handle /alertmanager* {
            reverse_proxy localhost:9093
          }


          # Blocky DNS API
          handle /blocky* {
            reverse_proxy localhost:4000
          }

          # SigNoz - Observability platform
          handle /signoz* {
            uri strip_prefix /signoz
            reverse_proxy localhost:3302
          }

          # Default landing page with template
          handle / {
            templates
            file_server {
              root /etc/caddy
              index dashboard.html
            }
          }
        '';
      };

      # Tailscale hostname access with HTTPS
      "router.bat-boa.ts.net" = {
        extraConfig = ''
          # Allow Tailscale network
          @blocked not remote_ip 100.64.0.0/10 ${netConfig.prefix}.0/${toString netConfig.cidr} 127.0.0.1
          respond @blocked "Access denied" 403

          # Same routing as main host
          handle /grafana* {
            reverse_proxy localhost:3000
          }

          handle /prometheus* {
            reverse_proxy localhost:9090
          }

          handle /alertmanager* {
            reverse_proxy localhost:9093
          }


          handle /blocky* {
            reverse_proxy localhost:4000
          }

          # SigNoz - Observability platform
          handle /signoz* {
            uri strip_prefix /signoz
            reverse_proxy localhost:3302
          }

          # Default landing page with template
          handle / {
            templates
            file_server {
              root /etc/caddy
              index dashboard.html
            }
          }
        '';
      };
    };
  };

  # Update Grafana configuration to work behind reverse proxy
  services.grafana.settings = lib.mkIf config.services.grafana.enable {
    server = {
      root_url = "/grafana/";
      serve_from_sub_path = true;
    };
  };

  # Update Prometheus configuration for reverse proxy
  services.prometheus = lib.mkMerge [
    (lib.mkIf config.services.prometheus.enable {
      webExternalUrl = "http://${routerIp}/prometheus/";
      extraFlags = [
        "--web.route-prefix=/prometheus"
      ];
    })
    (lib.mkIf config.services.prometheus.alertmanager.enable {
      alertmanager = {
        webExternalUrl = "http://${routerIp}/alertmanager/";
        extraFlags = [
          "--web.route-prefix=/alertmanager"
        ];
      };
    })
  ];

  # Open firewall ports for Caddy (only on LAN interface)
  networking.firewall.interfaces.br-lan = {
    allowedTCPPorts = [
      80 # HTTP
      443 # HTTPS
    ];
  };

  # Allow HTTPS on Tailscale interface for certificate validation
  networking.firewall.interfaces.tailscale0 = {
    allowedTCPPorts = [
      80 # HTTP (for ACME challenges)
      443 # HTTPS
    ];
  };

  # Allow Caddy to access Tailscale certificates
  services.tailscale.permitCertUid = "caddy";
}
