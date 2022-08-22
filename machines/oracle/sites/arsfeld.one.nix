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
        authorize with admin_one
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
    "bazarr.${domain}" = {
      useACMEHost = domain;
      extraConfig = ''
        reverse_proxy storage:6767
      '';
    };
    "stash.${domain}" = {
      useACMEHost = domain;
      extraConfig = ''
        reverse_proxy storage:9999
        authorize with admin_one
      '';
    };
    "netdata.${domain}" = {
      useACMEHost = domain;
      extraConfig = ''
        reverse_proxy storage:19999
        authorize with admin_one
      '';
    };
    "tautulli.${domain}" = {
      useACMEHost = domain;
      extraConfig = ''
        reverse_proxy storage:8181
        authorize with admin_one
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
        authorize with admin_one
      '';
    };
    "hass.${domain}" = {
      useACMEHost = domain;
      extraConfig = "reverse_proxy storage:8123";
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
    "auth.${domain}" = {
      useACMEHost = domain;
      extraConfig = "authenticate with myportal";
    };
  };
}
