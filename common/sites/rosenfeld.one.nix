{
  lib,
  config,
  pkgs,
  nixpkgs,
  modulesPath,
  ...
}:
with lib; let
  domain = "rosenfeld.one";
  email = "arsfeld@gmail.com";
in {
  services.caddy.email = email;

  services.caddy.virtualHosts = {
    "${domain}" = {
      extraConfig = ''
        handle_path /.well-known/webfinger {
          respond `
              {
                "subject": "acct:alex@rosenfeld.one",
                "links": [
                  {
                    "rel": "http://openid.net/specs/connect/1.0/issuer",
                    "href": "https://rosenfeld.one"
                  }
                ]
              }
            ` 200
        }
        reverse_proxy localhost:5556
      '';
    };
  };
}
