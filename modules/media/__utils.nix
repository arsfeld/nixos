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
          description = "Enable CORS for the media service";
        };
        insecureTls = mkOption {
          type = types.bool;
          default = false;
          description = "Enable insecure TLS for the media service";
        };
        bypassAuth = mkOption {
          type = types.bool;
          default = false;
          description = "Bypass authentication for the media service";
        };
        funnel = mkOption {
          type = types.bool;
          default = false;
          description = "Enable funnel for the media service";
        };
      };
    };

    # generateHost: Creates a Caddy virtual host configuration
    # Input: generateHost { domain = "example.com"; cfg = { name = "app"; host = "server1"; port = 8080; settings = {}; }; }
    # Output: { "app.example.com" = { useACMEHost = "example.com"; extraConfig = "..."; }; }
    generateHost = {
      domain,
      cfg,
    }: {
      "${cfg.name}.${domain}" = {
        useACMEHost = domain;
        extraConfig = let
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
            authURL = "https://${authHost}:${toString authPort}";
            authPath = "/api/verify?rd=https://auth.${config.media.gateway.domain}/";
            authCopyHeaders = {
              "Remote-User" = "Remote-User";
              "Remote-Groups" = "Remote-Groups";
              "Remote-Name" = "Remote-Name";
              "Remote-Email" = "Remote-Email";
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
        redir https://www.{host}{uri}
      }
    '';
  }
