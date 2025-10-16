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
#
# The gateway acts as a reverse proxy, routing requests to services
# based on subdomain (service.domain.com) and providing consistent
# authentication and security policies across all services.
{
  self,
  lib,
  config,
  ...
}:
with lib; let
  utils = import "${self}/modules/media/__utils.nix" {inherit config lib;};
  nameToPort = import "${self}/common/nameToPort.nix";
  cfg = config.media.gateway;
  _config = config;
  domain = cfg.domain;
  hosts = utils.generateHosts {
    services = cfg.services;
    domain = domain;
  };
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

    services.caddy.email = cfg.email;

    # Add Tailscale configuration to Caddy global config
    services.caddy.globalConfig = ''
      ${utils.generateCaddyGlobalConfig}

      # Tailscale configuration - makes Caddy join the Tailnet as a single node
      # Using OAuth client credentials for ephemeral node registration
      # See: https://github.com/tailscale/caddy-tailscale/pull/109
      tailscale {
        ${
        if cfg.tailscale.enableOAuth
        then ''
          client_id {$TS_API_CLIENT_ID}
          client_secret {$TS_API_CLIENT_SECRET}
        ''
        else ''
          auth_key {$TS_AUTHKEY}
        ''
      }
        ephemeral ${
        if cfg.tailscale.ephemeral
        then "true"
        else "false"
      }
        state_dir ${cfg.tailscale.stateDir}
      }
    '';

    services.caddy.extraConfig = utils.generateCaddyExtraConfig domain;

    services.caddy.virtualHosts = hosts;

    # Configure Caddy systemd service to use Tailscale OAuth credentials
    systemd.services.caddy.serviceConfig = {
      # Use tailscale-env which contains OAuth credentials:
      # - TS_API_CLIENT_ID (OAuth client ID)
      # - TS_API_CLIENT_SECRET (OAuth client secret)
      # - TS_AUTHKEY (legacy auth key, for fallback)
      EnvironmentFile = _config.age.secrets.tailscale-env.path;
      # Ensure state directory exists
      StateDirectory = lib.mkForce "caddy caddy/tailscale";
      # Ensure Caddy can bind to privileged ports (443, 80)
      AmbientCapabilities = lib.mkForce "CAP_NET_BIND_SERVICE";
    };
  };
}
