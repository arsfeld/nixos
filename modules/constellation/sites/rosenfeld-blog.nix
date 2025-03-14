{
  lib,
  config,
  ...
}:
with lib; let
  domain = "arosenfeld.blog";
in {
  options.constellation.sites.rosenfeld-blog = {
    enable = lib.mkEnableOption "rosenfeld-blog";
  };

  config = lib.mkIf config.constellation.sites.rosenfeld-blog.enable {
    security.acme.certs."${domain}" = {
      extraDomainNames = ["*.${domain}"];
    };

    services.caddy.virtualHosts = {
      "${domain}" = {
        useACMEHost = domain;
        extraConfig = "reverse_proxy localhost:2368";
      };
    };
  };
}
