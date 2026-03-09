{
  lib,
  config,
  self,
  ...
}:
with lib; let
  domain = "rosenfeld.one";
  nameToPort = import "${self}/common/nameToPort.nix";
  dexPort = nameToPort "dex";
  usersPort = nameToPort "users";
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
          reverse_proxy localhost:${toString dexPort}
        '';
      };
      "users.${domain}" = {
        useACMEHost = domain;
        extraConfig = "reverse_proxy localhost:${toString usersPort}";
      };
    };
  };
}
