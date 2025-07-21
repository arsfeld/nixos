{
  config,
  lib,
  pkgs,
  ...
}: let
  netConfig = config.router.network;
  routerIp = "${netConfig.prefix}.1";
  
  # Shared routing configuration for both internal IP and Tailscale access
  routerRoutes = ''
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

    # Router dashboard
    handle /dashboard* {
      reverse_proxy localhost:8080
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
in {
  # Dashboard template file
  environment.etc."caddy/dashboard.html".source = ./dashboard.html;

  # Caddy reverse proxy - internal access only (no WAN/public access)
  services.caddy = {
    enable = true;

    # Virtual host configuration
    virtualHosts = {
      # Internal IP access (HTTP only)
      "http://${routerIp}" = {
        extraConfig = ''
          # Restrict to internal network and Tailscale only
          @blocked not remote_ip ${netConfig.prefix}.0/${toString netConfig.cidr} 100.64.0.0/10 127.0.0.1
          respond @blocked "Access denied" 403

          ${routerRoutes}
        '';
      };

      # Tailscale hostname access (HTTPS with automatic certificates)
      "router.bat-boa.ts.net" = {
        extraConfig = ''
          # Restrict to internal network and Tailscale only
          @blocked not remote_ip ${netConfig.prefix}.0/${toString netConfig.cidr} 100.64.0.0/10 127.0.0.1
          respond @blocked "Access denied" 403

          ${routerRoutes}
        '';
      };
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
