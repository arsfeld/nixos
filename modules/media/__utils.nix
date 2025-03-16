{
  lib,
  config,
}: let
  authHost = config.media.gateway.authHost;
  authPort = config.media.gateway.authPort;
in
  with lib; rec {
    # generateHost: Creates a Caddy virtual host configuration
    # Input: generateHost "example.com" ["public"] ["api"] { name = "app"; host = "server1"; port = 8080; }
    # Output: { "app.example.com" = { useACMEHost = "example.com"; extraConfig = "..."; }; }
    generateHost = domain: bypassAuth: cors: cfg: {
      "${cfg.name}.${domain}" = {
        useACMEHost = domain;
        extraConfig =
          (
            if builtins.elem cfg.name bypassAuth
            then ""
            else ''
              forward_auth ${authHost}:${toString authPort} {
                uri /api/verify?rd=https://auth.${domain}/
                copy_headers Remote-User Remote-Groups Remote-Name Remote-Email
              }
            ''
          )
          + (
            if builtins.elem cfg.name cors
            then ""
            else ''
              import cors {header.origin}
            ''
          )
          + ''
            import errors
            reverse_proxy ${cfg.host}:${toString cfg.port} {
              @error status 404 500 503
              handle_response @error {
                error {rp.status_code}
              }
            }

          '';
      };
    };

    # generateTsnsrvService: Creates a tsnsrv service configuration if the service is on the current host
    # Input: generateTsnsrvService ["api"] { name = "api"; host = "localhost"; port = 3000; }
    # Output: { "api" = { toURL = "http://127.0.0.1:3000"; funnel = true; }; }
    generateTsnsrvService = funnels: cfg:
      if (config.networking.hostName == cfg.host)
      then {
        "${cfg.name}" = {
          toURL = "http://127.0.0.1:${toString cfg.port}";
          funnel = builtins.elem cfg.name funnels;
        };
      }
      else {};

    # generateConfigs: Transforms nested service definitions into a flat list of configs
    # Input: generateConfigs { server1 = { app = 8080; api = 3000; }; }
    # Output: [{ name = "app"; port = 8080; host = "server1"; } { name = "api"; port = 3000; host = "server1"; }]
    generateConfigs = services:
      concatLists (mapAttrsToList (host: pairs: mapAttrsToList (name: port: {inherit name port host;}) pairs) services);

    # generateTsnsrvConfigs: Creates tsnsrv service configurations from a list of configs
    # Input: generateTsnsrvConfigs [{ name = "api"; host = "localhost"; port = 3000; }] ["api"]
    # Output: { "api" = { toURL = "http://127.0.0.1:3000"; funnel = true; }; }
    generateTsnsrvConfigs = configs: funnels:
      foldl' (acc: host: acc // host) {} (map (generateTsnsrvService funnels) configs);

    # generateHosts: Creates Caddy virtual host configurations from a list of configs
    # Input: generateHosts [{ name = "app"; host = "server1"; port = 8080; }] "example.com" [] []
    # Output: { "app.example.com" = { useACMEHost = "example.com"; extraConfig = "..."; }; }
    generateHosts = configs: domain: bypassAuth: cors:
      foldl' (acc: host: acc // host) {} (map (generateHost domain bypassAuth cors) configs);

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
