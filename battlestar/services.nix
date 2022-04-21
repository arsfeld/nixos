{
  lib,
  config,
  pkgs,
  nixpkgs,
  modulesPath,
  ...
}:
with lib; let
  domain = "arsfeld.one";
  email = "arsfeld@gmail.com";
in {
  services.netdata.enable = true;

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

  users.users.caddy.extraGroups = ["acme"];

  services.caddy = {
    enable = true;
    email = email;
    acmeCA = "https://acme-staging-v02.api.letsencrypt.org/directory";
    virtualHosts = {
      "files.${domain}" = {
        useACMEHost = domain;
        extraConfig = "" "
            file_server {
                root /mnt/data
            }
        " "";
      };
    };
  };
}
