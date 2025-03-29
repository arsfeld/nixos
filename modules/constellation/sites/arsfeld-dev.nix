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

    services.caddy.virtualHosts = {
      "${domain}" = {
        useACMEHost = domain;
        extraConfig = "redir https://blog.${domain}";
      };
      "blog.${domain}" = {
        useACMEHost = domain;
        extraConfig = "reverse_proxy localhost:${toString config.media.gateway.services.ghost.port}";
      };
    };
  };
}
