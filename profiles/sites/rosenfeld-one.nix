{
  lib,
  config,
  pkgs,
  nixpkgs,
  modulesPath,
  self,
  ...
}:
with lib; let
  domain = "rosenfeld.one";
  email = "arsfeld@gmail.com";
  ports = (import "${self}/common/services.nix" {}).ports;
in {
  services.caddy.email = email;

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
}
