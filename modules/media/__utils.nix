{
  lib,
  config,
}: let
  authHost = config.media.gateway.authHost;
  authPort = config.media.gateway.authPort;
in
  with lib; rec {
    # generateHost: Creates a Caddy virtual host configuration
    # Input: generateHost { domain = "example.com"; bypassAuth = ["public"]; insecureTls = ["insecure"]; cors = ["api"]; cfg = { name = "app"; host = "server1"; port = 8080; }; }
    # Output: { "app.example.com" = { useACMEHost = "example.com"; extraConfig = "..."; }; }
    generateHost = {
      domain,
      bypassAuth,
      insecureTls,
      cors,
      cfg,
    }: {
      "${cfg.name}.${domain}" = {
        useACMEHost = domain;
        extraConfig = let
          authConfig = optionalString (!builtins.elem cfg.name bypassAuth) ''
            forward_auth ${authHost}:${toString authPort} {
              uri /api/verify?rd=https://auth.${domain}/
              copy_headers Remote-User Remote-Groups Remote-Name Remote-Email
            }
          '';
          protocol =
            if builtins.elem cfg.name insecureTls
            then "https"
            else "http";
          insecureTlsConfig = optionalString (builtins.elem cfg.name insecureTls) ''
            transport http {
                tls
                tls_insecure_skip_verify
            }
          '';
          corsConfig = optionalString (!builtins.elem cfg.name cors) ''
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
    generateTsnsrvService = {
      funnels,
      cfg,
    }:
      optionalAttrs (config.networking.hostName == cfg.host) {
        "${cfg.name}" = {
          toURL = "http://127.0.0.1:${toString cfg.port}";
          funnel = builtins.elem cfg.name funnels;
        };
      };

    # generateTsnsrvConfigs: Creates tsnsrv service configurations from a list of configs
    # Input: generateTsnsrvConfigs { configs = {"api": { name = "api"; host = "localhost"; port = 3000; }}; funnels = ["api"]; }
    # Output: { "api" = { toURL = "http://127.0.0.1:3000"; funnel = true; }; }
    generateTsnsrvConfigs = {
      services,
      funnels,
    }:
      builtins.foldl' (acc: cfg:
        acc
        // (generateTsnsrvService {
          funnels = funnels;
          cfg = cfg;
        })) {} (builtins.attrValues services);

    # generateHosts: Creates Caddy virtual host configurations from a list of configs
    # Input: generateHosts { services = {"app": { name = "app"; host = "server1"; port = 8080; }}; domain = "example.com"; bypassAuth = []; insecureTls = []; cors = []; }
    # Output: { "app.example.com" = { useACMEHost = "example.com"; extraConfig = "..."; }; }
    generateHosts = {
      services,
      domain,
      bypassAuth,
      insecureTls,
      cors,
    }:
      builtins.foldl' (acc: cfg:
        acc
        // (generateHost {
          domain = domain;
          bypassAuth = bypassAuth;
          insecureTls = insecureTls;
          cors = cors;
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
