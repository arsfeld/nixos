{
  lib,
  config,
  pkgs,
  nixpkgs,
  modulesPath,
  ...
}:
with lib; let
  cloudNode = "localhost";
  localNode = "striker.arsfeld.net";
  domain = "arsfeld.dev";
  email = "arsfeld@gmail.com";
in {
  security.acme = {
    acceptTerms = true;
    certs = {
      "${domain}" = {
        email = email;
        dnsProvider = "cloudflare";
        credentialsFile = "/var/lib/secrets/cloudflare";
        extraDomainNames = ["*.${domain}"];
      };
    };
  };

  #users.users.caddy.extraGroups = ["acme"];

  networking.firewall.allowedTCPPorts = [22 80 443];

  services.caddy = {
    enable = false;
    email = email;
    virtualHosts = {
      "files.${domain}" = {
        useACMEHost = domain;
        extraConfig = "reverse_proxy ${localNode}:8334";
      };
      "vault.${domain}" = {
        useACMEHost = domain;
        extraConfig = "reverse_proxy ${localNode}:8888";
      };
    };
  };
}
