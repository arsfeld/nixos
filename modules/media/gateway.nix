# Media gateway module
#
# This module provides a unified gateway for all media services, handling
# authentication, SSL termination, and routing through Caddy and tsnsrv.
#
# Key features:
# - Centralized authentication via Authelia
# - Automatic SSL certificate management
# - Service discovery and routing
# - Tailscale integration with optional public exposure
# - CORS and security header management
# - Error page handling
# - Support for both Podman and Kubernetes backends
#
# The gateway acts as a reverse proxy, routing requests to services
# based on subdomain (service.domain.com) and providing consistent
# authentication and security policies across all services.
#
# Routing behavior:
# - Podman backend: Routes to host:port where containers expose ports
# - Kubernetes backend: Routes to host:nodePort where k3s exposes services
#
# Tailscale exposure:
# - Podman backend: Uses tsnsrv for individual service nodes
# - Kubernetes backend: Uses Tailscale Kubernetes Operator annotations
{
  self,
  lib,
  config,
  pkgs,
  ...
}:
with lib; let
  utils = import "${self}/modules/media/__utils.nix" {inherit config lib pkgs;};
  nameToPort = import "${self}/common/nameToPort.nix";
  cfg = config.media.gateway;
  _config = config;
  domain = cfg.domain;
  hosts = utils.generateHosts {
    services = cfg.services;
    domain = domain;
  };

  # Check which backend is being used
  backend = config.media.backend or "podman";
  usePodman = backend == "podman";
  useKubernetes = backend == "kubernetes";
in {
  options.media.gateway = {
    enable = mkEnableOption "media gateway for service routing and authentication";

    services = mkOption {
      default = {};
      description = ''
        Services to expose through the gateway. Each service gets a subdomain
        and is accessible at <service-name>.<domain> with authentication.
      '';
      example = {
        jellyfin = {
          host = "storage";
          port = 8096;
        };
      };
      type = types.attrsOf (types.submodule ({config, ...}: {
        options = {
          enable = mkOption {
            type = types.bool;
            default = true;
            description = ''
              Whether to enable this service in the gateway.
              Disabled services won't be accessible through the gateway.
            '';
          };
          exposeViaTailscale = mkOption {
            type = types.bool;
            default = false;
            description = ''
              Whether to create a dedicated Tailscale node for this service.
              When enabled, the service gets its own <service>.bat-boa.ts.net hostname.
              When disabled, the service is only accessible via <service>.arsfeld.one through the cloud gateway.
              Default is false to reduce Tailscale node overhead and CPU usage.
            '';
          };
          name = mkOption {
            type = types.str;
            default = config._module.args.name;
            description = ''
              Name of the service. Used for subdomain generation and identification.
              Defaults to the attribute name in the services attrset.
            '';
            example = "jellyfin";
          };
          host = mkOption {
            type = types.str;
            default = _config.networking.hostName;
            description = ''
              Hostname where this service is running.
              The gateway will proxy requests to this host.
            '';
            example = "storage";
          };
          port = mkOption {
            type = types.int;
            default = nameToPort config.name;
            description = ''
              Port where the service is listening.
              Defaults to an automatically assigned port based on the service name.
            '';
          };
          settings = mkOption {
            type = utils.gatewayConfig;
            default = {};
            description = ''
              Additional gateway configuration for this service.
              Includes options for CORS, authentication bypass, TLS settings, and Tailscale Funnel.
            '';
          };
        };
      }));
    };

    authHost = mkOption {
      type = types.str;
      default = "cloud.bat-boa.ts.net";
      description = ''
        Hostname of the authentication service (Authelia).
        All requests are validated against this service before being proxied.
      '';
      example = "media.example.com";
    };

    authPort = mkOption {
      type = types.int;
      default = 443;
      description = ''
        Port where the authentication service is listening.
        Usually 443 for HTTPS or 9091 for direct Authelia access.
      '';
      example = 443;
    };

    domain = mkOption {
      type = types.str;
      default = _config.media.config.domain;
      description = ''
        Base domain for all media services.
        Services will be accessible at <service>.<domain>.
        SSL certificates will be obtained for this domain and all subdomains.
      '';
      example = "media.example.com";
    };

    email = mkOption {
      type = types.str;
      default = _config.media.config.email;
      description = ''
        Email address for ACME certificate notifications.
        Used by Let's Encrypt for important certificate-related communications.
      '';
      example = "media@example.com";
    };

    tailscale = {
      enable = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Enable Caddy Tailscale plugin integration.
          When disabled, Caddy will not create Tailscale nodes.
          Services with exposeViaTailscale will use tsnsrv instead.
          DISABLED by default due to high CPU usage (task-48, task-49).
        '';
      };

      enableOAuth = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Use OAuth client credentials (TS_API_CLIENT_ID + TS_API_CLIENT_SECRET)
          instead of auth key (TS_AUTHKEY) for Tailscale node registration.
          OAuth provides better security, scoping, and ephemeral node support.
        '';
      };

      ephemeral = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Enable ephemeral node registration with Tailscale.
          Ephemeral nodes are automatically cleaned up when they disconnect.
          Requires OAuth to be enabled.
        '';
      };

      stateDir = mkOption {
        type = types.str;
        default = "/var/lib/caddy/tailscale";
        description = ''
          Directory where Caddy will store Tailscale state.
          This directory must be persistent and writable by the caddy user.
        '';
      };
    };
  };

  config = lib.mkIf cfg.enable {
    security.acme.certs."${domain}" = {
      extraDomainNames = ["*.${domain}"];
    };

    # Configure tsnsrv services for Tailscale access (Podman backend only)
    # When using Kubernetes backend, the Tailscale Kubernetes Operator handles
    # service exposure via annotations on the Service resources.
    # Re-enabled as fallback from caddy-tailscale due to high CPU usage (task-48)
    services.tsnsrv.services = mkIf usePodman (utils.generateTsnsrvConfigs {
      services = cfg.services;
    });

    services.caddy.email = cfg.email;

    # Caddy Tailscale configuration DISABLED (task-48, task-49)
    # Using tsnsrv instead due to high CPU usage from caddy-tailscale plugin
    # tsnsrv provides the same Tailscale node functionality with lower overhead
    # See: services.tsnsrv.services configuration above
    services.caddy.globalConfig = ''
      ${utils.generateCaddyGlobalConfig}
    '';

    services.caddy.extraConfig = utils.generateCaddyExtraConfig domain;

    services.caddy.virtualHosts = hosts;

    # Configure Caddy systemd service
    # Tailscale OAuth credentials removed (task-48, task-49) - using tsnsrv instead
    systemd.services.caddy.serviceConfig = {
      # Ensure state directory exists for Caddy (no Tailscale subdirectories needed)
      StateDirectory = lib.mkForce ["caddy"];
      # Ensure Caddy can bind to privileged ports (443, 80)
      AmbientCapabilities = lib.mkForce "CAP_NET_BIND_SERVICE";
    };
  };
}
