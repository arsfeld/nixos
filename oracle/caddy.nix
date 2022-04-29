{
  lib,
  config,
  pkgs,
  nixpkgs,
  modulesPath,
  ...
}:
with lib; let
  cloudNode = "oracle.arsfeld.net";
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

  users.users.caddy.extraGroups = ["acme"];

  networking.firewall.allowedTCPPorts = [22 80 443];

  services.caddy = {
    enable = true;
    email = email;
    package = pkgs.callPackage ../pkgs/caddy.nix {
      plugins = [
        "github.com/greenpau/caddy-security"
      ];
      vendorSha256 = "sha256-TAENwTcwppwytl/ti6HGKkh6t9OjgJpUx7NwuGf+PCg=";
    };
    virtualHosts = {
      # Cloud
      "vault.${domain}" = {
        useACMEHost = domain;
        extraConfig = "reverse_proxy ${cloudNode}:8888";
      };
      "code.${domain}" = {
        useACMEHost = domain;
        extraConfig = "reverse_proxy ${cloudNode}:8443";
      };
      "yarr.${domain}" = {
        useACMEHost = domain;
        extraConfig = "reverse_proxy ${cloudNode}:7070";
      };

      # Local
      "files.${domain}" = {
        useACMEHost = domain;
        extraConfig = "reverse_proxy ${cloudNode}:8334";
      };
      "nzbhydra2.${domain}" = {
        useACMEHost = domain;
        extraConfig = "reverse_proxy ${cloudNode}:5076";
      };
      "jackett.${domain}" = {
        useACMEHost = domain;
        extraConfig = "reverse_proxy ${cloudNode}:9117";
      };
      "nzbget.${domain}" = {
        useACMEHost = domain;
        extraConfig = "reverse_proxy ${cloudNode}:6789";
      };
      "radarr.${domain}" = {
        useACMEHost = domain;
        extraConfig = "reverse_proxy ${cloudNode}:7878";
      };
      "sonarr.${domain}" = {
        useACMEHost = domain;
        extraConfig = "reverse_proxy ${cloudNode}:8989";
      };
      "sabnzbd.${domain}" = {
        useACMEHost = domain;
        extraConfig = "reverse_proxy ${cloudNode}:8880";
      };
      "stash.${domain}" = {
        useACMEHost = domain;
        extraConfig = "reverse_proxy ${cloudNode}:9999";
      };
      "syncthing.${domain}" = {
        useACMEHost = domain;
        extraConfig = "reverse_proxy ${cloudNode}:8384";
      };
    };
  };
}
