{
  lib,
  config,
  self,
  ...
}:
with lib; let
  domain = "rosenfeld.one";
  ports = config.mediaServices.ports;
in {
  options.constellation.sites.rosenfeld-one = {
    enable = lib.mkEnableOption "rosenfeld-one";
  };

  config = lib.mkIf config.constellation.sites.rosenfeld-one.enable {
    security.acme.certs."${domain}" = {
      extraDomainNames = ["*.${domain}"];
    };

    services.caddy.virtualHosts = {
      "${domain}" = {
        useACMEHost = domain;
        extraConfig = ''
          handle_path /.well-known/webfinger {
            respond `
                {
                  "subject": "{query.resource}",
                  "links": [
                    {
                      "rel": "http://openid.net/specs/connect/1.0/issuer",
                      "href": "https://rosenfeld.one"
                    }
                  ]
                }
              ` 200
          }
          reverse_proxy localhost:${toString ports.dex}
        '';
      };
      "users.${domain}" = {
        useACMEHost = domain;
        extraConfig = "reverse_proxy localhost:${toString ports.users}";
      };
    };
  };
}
