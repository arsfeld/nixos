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
  security.acme.certs."${domain}" = {
        email = email;
        dnsProvider = "cloudflare";
        credentialsFile = "/var/lib/secrets/cloudflare";
        extraDomainNames = ["*.${domain}"];
      };

  services.caddy.virtualHosts = {
      "files.${domain}" = {
        useACMEHost = domain;
        extraConfig = ''
          root * ${dataDir}
          file_server browse
        '';
      };
      "duplicati.${domain}" = {
        useACMEHost = domain;
        extraConfig = "reverse_proxy localhost:8200";
      };
      "vault.${domain}" = {
        useACMEHost = domain;
        extraConfig = ''
          reverse_proxy localhost:8000
        '';
      };
      "radarr.${domain}" = {
        useACMEHost = domain;
        extraConfig = ''
          reverse_proxy localhost:7878
          @api {
            not path /api/*
          }
          authorize @api with admin_policy
        '';
      };
      "sonarr.${domain}" = {
        useACMEHost = domain;
        extraConfig = ''
          reverse_proxy localhost:8989
          @api {
            not path /api/*
          }
          authorize @api with admin_policy
        '';
      };
      "bazarr.${domain}" = {
        useACMEHost = domain;
        extraConfig = ''
          reverse_proxy localhost:6767
          authorize with admin_policy
        '';
      };
      "qbittorrent.${domain}" = {
        useACMEHost = domain;
        extraConfig = "reverse_proxy localhost:8080";
      };
      "prowlarr.${domain}" = {
        useACMEHost = domain;
        extraConfig = "reverse_proxy localhost:9696";
      };
      "stash.${domain}" = {
        useACMEHost = domain;
        extraConfig = ''
          reverse_proxy localhost:9999
          authorize with admin_policy
        '';
      };
      "netdata.${domain}" = {
        useACMEHost = domain;
        extraConfig = ''
          reverse_proxy localhost:19999
          authorize with admin_policy
        '';
      };
      "tautulli.${domain}" = {
        useACMEHost = domain;
        extraConfig = ''
          reverse_proxy localhost:8181
          authorize with admin_policy
        '';
      };
      "jellyfin.${domain}" = {
        useACMEHost = domain;
        extraConfig = "reverse_proxy localhost:8096";
      };
      "nzbhydra2.${domain}" = {
        useACMEHost = domain;
        extraConfig = "reverse_proxy localhost:5076";
      };
      "sabnzbd.${domain}" = {
        useACMEHost = domain;
        extraConfig = ''
          reverse_proxy localhost:8888
          authorize with admin_policy
        '';
      };
      "hass.${domain}" = {
        useACMEHost = domain;
        extraConfig = "reverse_proxy striker:8123";
      };
      "code.${domain}" = {
        useACMEHost = domain;
        extraConfig = ''
          reverse_proxy localhost:4444
        '';
      };
      "dev.${domain}" = {
        useACMEHost = domain;
        extraConfig = ''
          reverse_proxy striker:4444
        '';
      };
      "auth.${domain}" = {
        useACMEHost = domain;
        extraConfig = "authenticate with myportal";
      };
    };
}
