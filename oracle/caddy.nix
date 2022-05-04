{
  lib,
  config,
  pkgs,
  nixpkgs,
  modulesPath,
  ...
}:
with lib; let
  cloudNode = "oracle";
  localNode = "storage";
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
      "yarr.${domain}" = {
        useACMEHost = domain;
        extraConfig = "reverse_proxy ${cloudNode}:7070";
      };
      "blog.${domain}" = {
        useACMEHost = domain;
        extraConfig = "reverse_proxy ${cloudNode}:2368";
      };

      # Local
      "code.${domain}" = {
        useACMEHost = domain;
        extraConfig = "reverse_proxy ${localNode}:4444";
      };
      "files.${domain}" = {
        useACMEHost = domain;
        extraConfig = "reverse_proxy ${localNode}:8334";
      };
      "nzbhydra2.${domain}" = {
        useACMEHost = domain;
        extraConfig = "reverse_proxy ${localNode}:5076";
      };
      "jackett.${domain}" = {
        useACMEHost = domain;
        extraConfig = "reverse_proxy ${localNode}:9117";
      };
      "nzbget.${domain}" = {
        useACMEHost = domain;
        extraConfig = "reverse_proxy ${localNode}:6789";
      };
      "radarr.${domain}" = {
        useACMEHost = domain;
        extraConfig = "reverse_proxy ${localNode}:7878";
      };
      "sonarr.${domain}" = {
        useACMEHost = domain;
        extraConfig = "reverse_proxy ${localNode}:8989";
      };
      "sabnzbd.${domain}" = {
        useACMEHost = domain;
        extraConfig = "reverse_proxy ${localNode}:8880";
      };
      "stash.${domain}" = {
        useACMEHost = domain;
        extraConfig = "reverse_proxy ${localNode}:9999";
      };
      "syncthing.${domain}" = {
        useACMEHost = domain;
        extraConfig = "reverse_proxy ${localNode}:8384";
      };
    };
  };
}
