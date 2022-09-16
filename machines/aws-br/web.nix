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
  dataDir = "/mnt/media";
in {
  users.users.caddy.extraGroups = ["acme"];

  security.acme = {
    acceptTerms = true;
  };


  security.acme.certs."${domain}" = {
    email = email;
    dnsProvider = "cloudflare";
    credentialsFile = "/var/lib/secrets/cloudflare";
    extraDomainNames = ["*.${domain}"];
  };

  services.caddy.virtualHosts = {


  services.caddy = {
    enable = true;
    email = email;

    virtualHosts = {
      "radarr.${domain}" = {
        useACMEHost = domain;
        extraConfig = "reverse_proxy localhost:8200";
      };
    };
  };
}
