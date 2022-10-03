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
  security.acme.certs."${domain}" = {
    email = email;
    dnsProvider = "cloudflare";
    credentialsFile = "/var/lib/secrets/cloudflare";
    extraDomainNames = ["*.${domain}"];
  };

  services.caddy.email = email;

  services.caddy.virtualHosts = {
    "duplicati.${domain}" = {
      useACMEHost = domain;
      extraConfig = "reverse_proxy storage:8200";
    };
    "vault.${domain}" = {
      useACMEHost = domain;
      extraConfig = ''
        reverse_proxy storage:8000
      '';
    };
    "radarr.${domain}" = {
      useACMEHost = domain;
      extraConfig = ''
        reverse_proxy storage:7878
      '';
    };
    "jackett.${domain}" = {
      useACMEHost = domain;
      extraConfig = ''
        reverse_proxy storage:9117
      '';
    };
    "sonarr.${domain}" = {
      useACMEHost = domain;
      extraConfig = ''
        reverse_proxy storage:8989
      '';
    };
    "bazarr.${domain}" = {
      useACMEHost = domain;
      extraConfig = ''
        reverse_proxy storage:6767
      '';
    };
    "qbittorrent.${domain}" = {
      useACMEHost = domain;
      extraConfig = "reverse_proxy storage:8080";
    };
    "prowlarr.${domain}" = {
      useACMEHost = domain;
      extraConfig = "reverse_proxy storage:9696";
    };
    "stash.${domain}" = {
      useACMEHost = domain;
      extraConfig = ''
        reverse_proxy storage:9999
      '';
    };
    "netdata.${domain}" = {
      useACMEHost = domain;
      extraConfig = ''
        reverse_proxy storage:19999
      '';
    };
    "tautulli.${domain}" = {
      useACMEHost = domain;
      extraConfig = ''
        reverse_proxy storage:8181
      '';
    };
    "jellyfin.${domain}" = {
      useACMEHost = domain;
      extraConfig = "reverse_proxy storage:8096";
    };
    "nzbhydra2.${domain}" = {
      useACMEHost = domain;
      extraConfig = "reverse_proxy storage:5076";
    };
    "sabnzbd.${domain}" = {
      useACMEHost = domain;
      extraConfig = ''
        reverse_proxy storage:8888
      '';
    };
    "hass.${domain}" = {
      useACMEHost = domain;
      extraConfig = "reverse_proxy storage:8123";
    };
    "dev.${domain}" = {
      useACMEHost = domain;
      extraConfig = ''
        reverse_proxy dev:8000
      '';
    };
    "code.${domain}" = {
      useACMEHost = domain;
      extraConfig = ''
        reverse_proxy storage:4444
      '';
    };
    "filerun.${domain}" = {
      useACMEHost = domain;
      extraConfig = ''
        reverse_proxy storage:6000
      '';
    };
    "nextcloud.${domain}" = {
      useACMEHost = domain;
      extraConfig = ''
        rewrite /.well-known/carddav /remote.php/dav
        rewrite /.well-known/caldav /remote.php/dav

        reverse_proxy storage:80
      '';
    };
  };
}
