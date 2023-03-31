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
        redir /.well-known/webfinger /webfinger/{query.resource}.json
        @httpwebfinger {
          path_regexp webfinger /webfinger/https?://(.+)
        }
        rewrite @httpwebfinger /webfinger/{re.webfinger.1}
      '';
    };
    "cloak.${domain}" = {
      extraConfig = "reverse_proxy storage:38080";
    };
  };
}
