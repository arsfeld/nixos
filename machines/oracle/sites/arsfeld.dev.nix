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
        authorize @api with admin_dev
      '';
    };
    "sonarr.${domain}" = {
      useACMEHost = domain;
      extraConfig = ''
        reverse_proxy localhost:8989
        @api {
          not path /api/*
        }
        authorize @api with admin_dev
      '';
    };
    "bazarr.${domain}" = {
      useACMEHost = domain;
      extraConfig = ''
        reverse_proxy localhost:6767
        authorize with admin_dev
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
        authorize with admin_dev
      '';
    };
    "netdata.${domain}" = {
      useACMEHost = domain;
      extraConfig = ''
        reverse_proxy localhost:19999
        authorize with admin_dev
      '';
    };
    "tautulli.${domain}" = {
      useACMEHost = domain;
      extraConfig = ''
        reverse_proxy localhost:8181
        authorize with admin_dev
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
        authorize with admin_dev
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
    "headscale.${domain}" = {
      useACMEHost = domain;
      extraConfig = ''
        reverse_proxy /web* storage:9899
        reverse_proxy localhost:9898
        authorize with admin_dev
      '';
    };
    "auth.${domain}" = {
      useACMEHost = domain;
      extraConfig = "authenticate with myportal";
    };
  };
}
