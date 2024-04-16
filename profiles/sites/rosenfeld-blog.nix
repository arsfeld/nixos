{
  lib,
  config,
  pkgs,
  nixpkgs,
  modulesPath,
  ...
}:
with lib; let
  domain = "arosenfeld.blog";
  email = "arsfeld@gmail.com";
in {
  security.acme.certs."${domain}" = {
    extraDomainNames = ["*.${domain}"];
  };

  services.caddy.email = email;

  services.caddy.virtualHosts = {
    "${domain}" = {
      useACMEHost = domain;
      extraConfig = "reverse_proxy localhost:2368";
    };
  };
}
