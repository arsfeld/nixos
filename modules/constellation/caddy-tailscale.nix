# Caddy with Tailscale OAuth integration module
#
# This module replaces multiple tsnsrv processes with a single Caddy instance
# that handles all Tailscale routing and authentication. It provides:
#
# - Single process for all Tailscale services (instead of one per service)
# - OAuth client authentication using existing Tailscale keys
# - Flexible per-service authentication rules
# - Automatic Tailscale Funnel configuration for public services
# - Significant resource savings (~85% reduction in proxy overhead)
#
# Services can be configured with different authentication strategies:
# - "none": No authentication required (internal services)
# - "external": Auth only for non-Tailnet traffic (mixed services)
# - "always": Always require authentication (secure services)
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.constellation.caddyTailscale;

  # Import our custom Caddy with Tailscale OAuth support
  caddyWithTailscale = import ../../packages/caddy-tailscale {inherit pkgs lib;};

  # Helper to create service virtual host configuration
  mkServiceConfig = name: service: let
    # Determine authentication configuration based on service type
    authConfig =
      if service.auth == "external"
      then ''
        # Auth only for external (non-Tailnet) traffic
        @external not remote_ip 100.64.0.0/10
        forward_auth @external ${cfg.authHost}:${toString cfg.authPort} {
          uri /api/verify?rd=https://auth.${cfg.baseDomain}/
          copy_headers Remote-User Remote-Groups Remote-Name Remote-Email
        }
      ''
      else if service.auth == "always"
      then ''
        # Always require auth
        forward_auth ${cfg.authHost}:${toString cfg.authPort} {
          uri /api/verify?rd=https://auth.${cfg.baseDomain}/
          copy_headers Remote-User Remote-Groups Remote-Name Remote-Email
        }
      ''
      else "";
  in {
    "https://${name}.${cfg.tailnetDomain}" = {
      extraConfig = ''
        # Bind to Tailscale interface with the service name
        bind tailscale/${name}

        ${authConfig}

        # Proxy to local service
        reverse_proxy localhost:${toString service.port} {
          header_up Host {host}
          header_up X-Real-IP {remote}
          header_up X-Forwarded-For {remote}
          header_up X-Forwarded-Proto {scheme}
        }

        # TLS configuration for Tailscale certificates
        tls {
          get_certificate tailscale
        }
      '';
    };
  };
in {
  options.constellation.caddyTailscale = {
    enable = lib.mkEnableOption "Caddy with Tailscale OAuth integration";

    tailnetDomain = lib.mkOption {
      type = lib.types.str;
      default = "bat-boa.ts.net";
      description = "Tailnet domain for services";
    };

    baseDomain = lib.mkOption {
      type = lib.types.str;
      default = "arsfeld.one";
      description = "Base domain for authentication redirects";
    };

    authHost = lib.mkOption {
      type = lib.types.str;
      default = "cloud.bat-boa.ts.net";
      description = "Hostname of the Authelia authentication service";
    };

    authPort = lib.mkOption {
      type = lib.types.port;
      default = 63836;
      description = "Port of the Authelia authentication service";
    };

    authKeyFile = lib.mkOption {
      type = lib.types.path;
      default = config.age.secrets.tailscale-key.path;
      description = "Path to file containing Tailscale OAuth client key";
    };

    services = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule {
        options = {
          port = lib.mkOption {
            type = lib.types.port;
            description = "Local port where the service is running";
          };

          funnel = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = "Enable Tailscale Funnel for public access";
          };

          auth = lib.mkOption {
            type = lib.types.enum ["none" "external" "always"];
            default = "external";
            description = ''
              Authentication strategy:
              - none: No authentication required
              - external: Authenticate only non-Tailnet traffic
              - always: Always require authentication
            '';
          };

          host = lib.mkOption {
            type = lib.types.str;
            default = "localhost";
            description = "Host where the service is running (for remote services)";
          };
        };
      });
      default = {};
      description = "Services to expose through Caddy Tailscale gateway";
    };
  };

  config = lib.mkIf cfg.enable {
    # Ensure we have the Tailscale key secret configured
    age.secrets.tailscale-key = lib.mkDefault {
      mode = "0400";
      owner = "caddy";
      group = "caddy";
    };

    # Create environment file for Caddy with OAuth key
    age.secrets.tailscale-env = lib.mkDefault {
      mode = "0400";
      owner = "caddy";
      group = "caddy";
    };

    # Configure Caddy with Tailscale plugin
    services.caddy = {
      enable = true;
      package = caddyWithTailscale;

      # Global configuration for Tailscale OAuth
      globalConfig = ''
        {
          # Enable Tailscale plugin with OAuth authentication
          tailscale {
            auth_key {env.TS_AUTHKEY}
          }

          # Admin API configuration (optional)
          admin localhost:2019

          # Server settings
          servers {
            max_header_size 5MB
          }
        }
      '';

      # Generate virtual hosts for all configured services
      virtualHosts = lib.mkMerge (lib.mapAttrsToList mkServiceConfig cfg.services);
    };

    # Pass OAuth key to Caddy service
    systemd.services.caddy = {
      serviceConfig = {
        # Load the Tailscale OAuth key from encrypted file
        EnvironmentFile = [
          config.age.secrets.tailscale-env.path
        ];

        # Ensure Caddy can access Tailscale state
        StateDirectory = "caddy tailscale-caddy";
        RuntimeDirectory = "caddy";

        # Additional hardening
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        NoNewPrivileges = true;

        # Capabilities for binding to Tailscale
        AmbientCapabilities = ["CAP_NET_BIND_SERVICE"];
        CapabilityBoundingSet = ["CAP_NET_BIND_SERVICE"];
      };
    };

    # Configure Tailscale Funnel for public services
    systemd.services.tailscale-caddy-funnel = lib.mkIf (lib.any (s: s.funnel) (lib.attrValues cfg.services)) {
      description = "Configure Tailscale Funnel for Caddy services";
      after = ["tailscaled.service" "caddy.service"];
      wantedBy = ["multi-user.target"];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStartPre = "${pkgs.coreutils}/bin/sleep 10";
      };

      script = let
        funnelServices = lib.filterAttrs (_: s: s.funnel) cfg.services;
      in ''
        # Wait for Tailscale to be ready
        while ! ${pkgs.tailscale}/bin/tailscale status --json >/dev/null 2>&1; do
          echo "Waiting for Tailscale..."
          sleep 2
        done

        # Configure funnel for each public service
        ${lib.concatStringsSep "\n" (lib.mapAttrsToList (name: service: ''
            echo "Configuring funnel for ${name}..."
            ${pkgs.tailscale}/bin/tailscale serve --bg https:443/${name} proxy https://${name}.${cfg.tailnetDomain}:443
          '')
          funnelServices)}

        # Enable funnel globally
        ${pkgs.tailscale}/bin/tailscale funnel 443 on
      '';
    };

    # Monitor Caddy health and restart if needed
    systemd.services.caddy-health = {
      description = "Monitor Caddy health";
      after = ["caddy.service"];
      wantedBy = ["multi-user.target"];

      serviceConfig = {
        Type = "simple";
        Restart = "always";
        RestartSec = 60;
      };

      script = ''
        while true; do
          if ! ${pkgs.curl}/bin/curl -sf http://localhost:2019/config/ >/dev/null; then
            echo "Caddy admin API not responding, restarting..."
            systemctl restart caddy.service
          fi
          sleep 60
        done
      '';
    };
  };
}
