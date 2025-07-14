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
  tsnsrvConfigs = utils.generateTsnsrvConfigs {
    services = cfg.services;
  };
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
  };

  config = lib.mkIf cfg.enable {
    security.acme.certs."${domain}" = {
      extraDomainNames = ["*.${domain}"];
    };

    services.tsnsrv.services = tsnsrvConfigs;

    services.caddy.email = cfg.email;

    services.caddy.globalConfig = utils.generateCaddyGlobalConfig;

    services.caddy.extraConfig = utils.generateCaddyExtraConfig domain;

    services.caddy.virtualHosts = hosts;
  };
}
