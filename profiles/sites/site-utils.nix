{lib}:
with lib; rec {
  generateHost = domain: bypassAuth: cors: cfg: {
    "${cfg.name}.${domain}" = {
      useACMEHost = domain;
      extraConfig =
        (
          if builtins.elem cfg.name bypassAuth
          then ""
          else ''
            forward_auth cloud:9099 {
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

  generateService = config: funnels: cfg:
    if (config.networking.hostName == cfg.host)
    then {
      "${cfg.name}" = {
        toURL = "http://127.0.0.1:${toString cfg.port}";
        funnel = builtins.elem cfg.name funnels;
      };
    }
    else {};

  generateConfigs = services:
    concatLists (mapAttrsToList (host: pairs: mapAttrsToList (name: port: {inherit name port host;}) pairs) services);

  generateTsnsrvConfigs = configs: funnels: config:
    foldl' (acc: host: acc // host) {} (map (generateService config funnels) configs);

  generateHosts = configs: domain: bypassAuth: cors:
    foldl' (acc: host: acc // host) {} (map (generateHost domain bypassAuth cors) configs);

  generateCaddyGlobalConfig = ''
    servers {
      max_header_size 5MB
    }
  '';

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
