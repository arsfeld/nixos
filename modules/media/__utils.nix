# Media gateway utility functions
#
# This module provides shared utility functions and types for the media gateway
# system. It includes helpers for generating Caddy configurations, tsnsrv service
# definitions, and common configuration patterns.
#
# Key components:
# - Gateway configuration type with auth, CORS, and TLS options
# - Caddy virtual host generation with authentication integration
# - tsnsrv service configuration for Tailscale access
# - CORS and error page handling snippets
# - Domain wildcard and redirect configurations
#
# These utilities ensure consistent configuration across all media services
# with proper authentication, security headers, and error handling.
{
  lib,
  config,
}:
with lib; let
  authHost = config.media.gateway.authHost;
  authPort = config.media.gateway.authPort;
in
  with lib; rec {
    gatewayConfig = types.submodule {
      options = {
        cors = mkOption {
          type = types.bool;
          default = false;
          description = ''
            Enable Cross-Origin Resource Sharing (CORS) headers for this service.
            Required for web applications that need to access the service from different domains.
          '';
        };
        insecureTls = mkOption {
          type = types.bool;
          default = false;
          description = ''
            Skip TLS certificate verification when proxying to this service.
            Only use for services with self-signed certificates in development.
          '';
        };
        bypassAuth = mkOption {
          type = types.bool;
          default = false;
          description = ''
            Bypass authentication checks for this service.
            WARNING: This makes the service publicly accessible without authentication.
          '';
        };
        funnel = mkOption {
          type = types.bool;
          default = false;
          description = ''
            Enable Tailscale Funnel for this service, making it accessible
            from the public internet through Tailscale's edge servers.
          '';
        };
      };
    };

    # generateTailscaleNodes: Creates named Tailscale node configurations for each service
    # Input: generateTailscaleNodes { radarr = { name = "radarr"; host = "storage"; exposeViaTailscale = true; ... }; sonarr = { name = "sonarr"; exposeViaTailscale = false; ... }; }
    # Output: "radarr { hostname radarr state_dir /var/lib/caddy/tailscale/radarr }" (sonarr excluded)
    # Only creates nodes for services with exposeViaTailscale = true AND host = current hostname
    generateTailscaleNodes = services: let
      currentHost = config.networking.hostName;
      # Filter to only enabled services that should be exposed via Tailscale on THIS host
      exposedServices = builtins.filter (cfg: cfg.enable && cfg.exposeViaTailscale && cfg.host == currentHost) (builtins.attrValues services);
      generateNode = cfg: ''
        ${cfg.name} {
          hostname ${cfg.name}
          state_dir /var/lib/caddy/tailscale/${cfg.name}
        }
      '';
    in
      lib.concatMapStringsSep "\n" generateNode exposedServices;

    # generateHost: Creates a Caddy virtual host configuration
    # Input: generateHost { domain = "example.com"; cfg = { name = "app"; host = "server1"; port = 8080; exposeViaTailscale = true; settings = {}; }; }
    # Output: { "app.example.com" = { useACMEHost = "example.com"; extraConfig = "..."; }; }
    generateHost = {
      domain,
      cfg,
    }: {
      "${cfg.name}.${domain}" = {
        useACMEHost = domain;
        extraConfig = let
          currentHost = config.networking.hostName;
          # Bind this virtual host to its own Tailscale node only if:
          # 1. exposeViaTailscale is enabled
          # 2. The service runs on THIS host (otherwise the node won't exist)
          # This creates one Tailscale node per service, enabling individual *.bat-boa.ts.net hostnames
          # See: https://github.com/tailscale/caddy-tailscale#multiple-nodes
          bindConfig = optionalString (cfg.exposeViaTailscale && cfg.host == currentHost) ''
            bind tailscale/${cfg.name}
          '';
          authConfig = optionalString (!cfg.settings.bypassAuth) ''
            forward_auth ${authHost}:${toString authPort} {
              uri /api/verify?rd=https://auth.${domain}/
              copy_headers Remote-User Remote-Groups Remote-Name Remote-Email
            }
          '';
          protocol =
            if cfg.settings.insecureTls
            then "https"
            else "http";
          insecureTlsConfig = optionalString (cfg.settings.insecureTls) ''
            transport http {
                tls
                tls_insecure_skip_verify
            }
          '';
          corsConfig = optionalString (cfg.settings.cors) ''
            import cors {header.origin}
          '';
          proxyConfig = ''
            import errors
            reverse_proxy ${protocol}://${cfg.host}:${toString cfg.port} {
              ${insecureTlsConfig}
              @error status 404 500 503
              handle_response @error {
                error {rp.status_code}
              }
            }
          '';
        in ''
          ${bindConfig}
          ${authConfig}
          ${corsConfig}
          ${proxyConfig}
        '';
      };
    };

    # generateTsnsrvService: Creates a tsnsrv service configuration if the service is on the current host
    # Input: generateTsnsrvService { funnels = ["api"]; cfg = { name = "api"; host = "localhost"; port = 3000; }; }
    # Output: { "api" = { toURL = "http://127.0.0.1:3000"; funnel = true; }; }
    generateTsnsrvService = {cfg}:
      optionalAttrs (config.networking.hostName == cfg.host) {
        "${cfg.name}" =
          {
            toURL = "http://127.0.0.1:${toString cfg.port}";
            funnel = cfg.settings.funnel;
          }
          // (optionalAttrs (!cfg.settings.bypassAuth) {
            authURL = "http://${authHost}:${toString authPort}";
            authPath = "/api/authz/forward-auth";
            authBypassForTailnet = true;
            authCopyHeaders = {
              "Remote-User" = "";
              "Remote-Groups" = "";
              "Remote-Name" = "";
              "Remote-Email" = "";
            };
          });
      };

    # generateTsnsrvConfigs: Creates tsnsrv service configurations from a list of configs
    # Input: generateTsnsrvConfigs { configs = {"api": { name = "api"; host = "localhost"; port = 3000; }}; funnels = ["api"]; }
    # Output: { "api" = { toURL = "http://127.0.0.1:3000"; funnel = true; }; }
    generateTsnsrvConfigs = {services}:
      builtins.foldl' (acc: cfg:
        acc
        // (generateTsnsrvService {
          cfg = cfg;
        })) {} (builtins.attrValues services);

    # generateHosts: Creates Caddy virtual host configurations from a list of configs
    # Input: generateHosts { services = {"app": { name = "app"; host = "server1"; port = 8080; }}; domain = "example.com"; bypassAuth = []; insecureTls = []; cors = []; }
    # Output: { "app.example.com" = { useACMEHost = "example.com"; extraConfig = "..."; }; }
    generateHosts = {
      services,
      domain,
    }:
      builtins.foldl' (acc: cfg:
        acc
        // (generateHost {
          domain = domain;
          cfg = cfg;
        })) {} (builtins.attrValues services);

    # generateCaddyGlobalConfig: Returns Caddy global server settings
    # Input: generateCaddyGlobalConfig
    # Output: "servers { max_header_size 5MB }"
    generateCaddyGlobalConfig = ''
      servers {
        max_header_size 5MB
      }
    '';

    # generateCaddyExtraConfig: Creates Caddy configuration snippets for CORS, errors, and domain redirects
    # Input: generateCaddyExtraConfig "example.com"
    # Output: "(cors) { ... } (errors) { ... } *.example.com { ... } example.com { ... }"
    generateCaddyExtraConfig = domain: ''
      (cors) {
        @cors_preflight method OPTIONS

        header {
          Access-Control-Allow-Origin "{header.origin}"
          Vary Origin
          Access-Control-Expose-Headers "Authorization"
          Access-Control-Allow-Credentials "true"
        }

        handle @cors_preflight {
          header {
            Access-Control-Allow-Methods "GET, POST, PUT, PATCH, DELETE"
            Access-Control-Max-Age "3600"
          }
          respond "" 204
        }
      }

      (errors) {
        handle_errors {
          rewrite * /error-pages/l7/{err.status_code}.html
          reverse_proxy https://tarampampam.github.io {
            header_up Host {upstream_hostport}
            replace_status {err.status_code}
          }
        }
      }

      *.${domain} {
        import errors
        error 404
      }

      ${domain} {
        redir https://www.${domain}{uri}
      }
    '';
  }
