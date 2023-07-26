{
  lib,
  config,
  pkgs,
  nixpkgs,
  modulesPath,
  ...
}:
with lib; let
  domain = "arsfeld.dev";
  email = "arsfeld@gmail.com";
in {
  security.acme.certs."${domain}" = {
    extraDomainNames = ["*.${domain}"];
  };

  services.caddy.email = email;

  services.caddy.virtualHosts = {
    "${domain}" = {
      useACMEHost = domain;
      extraConfig = "redir https://blog.${domain}";
    };
    "blog.${domain}" = {
      useACMEHost = domain;
      extraConfig = "reverse_proxy localhost:2368";
    };
  };
}
