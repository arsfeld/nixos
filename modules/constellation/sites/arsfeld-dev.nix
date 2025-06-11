{
  lib,
  config,
  ...
}: let
  domain = "arsfeld.dev";
in {
  options.constellation.sites.arsfeld-dev = {
    enable = lib.mkEnableOption "arsfeld-dev";
  };

  config = lib.mkIf config.constellation.sites.arsfeld-dev.enable {
    security.acme.certs."${domain}" = {
      extraDomainNames = ["*.${domain}"];
    };

    services.caddy.virtualHosts =
      {
        "${domain}" = {
          useACMEHost = domain;
          extraConfig = "redir https://blog.${domain}";
        };
        # blog.${domain} is now handled directly by constellation.blog module
      }
      // lib.optionalAttrs (config.constellation.supabase.enable or false) (
        lib.mapAttrs' (name: instanceCfg: {
          name = "${instanceCfg.subdomain}.${domain}";
          value = {
            useACMEHost = domain;
            extraConfig = ''
              # CORS headers for Supabase
              header {
                Access-Control-Allow-Origin "*"
                Access-Control-Allow-Methods "GET, POST, PUT, DELETE, OPTIONS, PATCH"
                Access-Control-Allow-Headers "Content-Type, Authorization, apikey, x-client-info, x-supabase-api-version"
                Access-Control-Expose-Headers "x-supabase-api-version"
              }

              # Handle preflight requests
              @cors_preflight method OPTIONS
              respond @cors_preflight 200

              # Proxy to Supabase instance
              reverse_proxy localhost:${toString instanceCfg.port} {
                header_up Host {http.request.host}
                header_up X-Real-IP {http.request.remote}
                header_up X-Forwarded-For {http.request.remote}
                header_up X-Forwarded-Proto {http.request.scheme}
              }
            '';
          };
        }) (lib.filterAttrs (name: cfg: cfg.enable) config.constellation.supabase.instances)
      );
  };
}
