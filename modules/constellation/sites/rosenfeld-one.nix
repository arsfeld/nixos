{
  lib,
  config,
  self,
  ...
}:
with lib; let
  cfg = config.constellation.sites.rosenfeld-one;
  domain = "rosenfeld.one";
  nameToPort = import "${self}/common/nameToPort.nix";
  dexPort = nameToPort "dex";
  usersPort = nameToPort "users";
in {
  options.constellation.sites.rosenfeld-one = {
    enable = lib.mkEnableOption "rosenfeld-one";
    dexUpstream = lib.mkOption {
      type = lib.types.str;
      default = "localhost:${toString dexPort}";
      description = "Upstream address for dex OIDC provider";
    };
    usersUpstream = lib.mkOption {
      type = lib.types.str;
      default = "localhost:${toString usersPort}";
      description = "Upstream address for LLDAP users interface";
    };
  };

  config = lib.mkIf cfg.enable {
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
          reverse_proxy ${cfg.dexUpstream}
        '';
      };
      "users.${domain}" = {
        useACMEHost = domain;
        extraConfig = "reverse_proxy ${cfg.usersUpstream}";
      };
    };
  };
}
