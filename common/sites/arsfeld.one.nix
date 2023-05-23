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
    extraDomainNames = ["*.${domain}"];
  };

  services.caddy.email = email;

  services.caddy.virtualHosts = {
    "vault.${domain}" = {
      useACMEHost = domain;
      extraConfig = "reverse_proxy micro:8000";
    };
    "yarr.${domain}" = {
      useACMEHost = domain;
      extraConfig = "reverse_proxy micro:7070";
    };
    "minio.${domain}" = {
      useACMEHost = domain;
      extraConfig = "reverse_proxy storage:9000";
    };
    "gitea.${domain}" = {
      useACMEHost = domain;
      extraConfig = "reverse_proxy storage:3001";
    };
    "speedtest.${domain}" = {
      useACMEHost = domain;
      extraConfig = "reverse_proxy storage:8765";
    };
    "photos.${domain}" = {
      useACMEHost = domain;
      extraConfig = "reverse_proxy storage:15777";
    };
    "immich.${domain}" = {
      useACMEHost = domain;
      extraConfig = "reverse_proxy storage:15777";
    };
    "duplicati.${domain}" = {
      useACMEHost = domain;
      extraConfig = "reverse_proxy storage:8200";
    };
    "radarr.${domain}" = {
      useACMEHost = domain;
      extraConfig = ''
        reverse_proxy storage:7878
      '';
    };
    "lidarr.${domain}" = {
      useACMEHost = domain;
      extraConfig = "reverse_proxy storage:8686";
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
    "whisparr.${domain}" = {
      useACMEHost = domain;
      extraConfig = "reverse_proxy storage:6969";
    };
    "qbittorrent.${domain}" = {
      useACMEHost = domain;
      extraConfig = "reverse_proxy storage:8080";
    };
    "qflood.${domain}" = {
      useACMEHost = domain;
      extraConfig = "reverse_proxy storage:3000";
    };
    "prowlarr.${domain}" = {
      useACMEHost = domain;
      extraConfig = "reverse_proxy storage:9696";
    };
    "flaresolverr.${domain}" = {
      useACMEHost = domain;
      extraConfig = "reverse_proxy storage:8191";
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
    "jf.${domain}" = {
      useACMEHost = domain;
      extraConfig = "reverse_proxy storage:3831";
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
      extraConfig = "reverse_proxy raspi3:8123";
    };
    "grafana.${domain}" = {
      useACMEHost = domain;
      extraConfig = "reverse_proxy storage:2345";
    };
    "dev.${domain}" = {
      useACMEHost = domain;
      extraConfig = ''
        reverse_proxy cloud:8000
      '';
    };
    "code.${domain}" = {
      useACMEHost = domain;
      extraConfig = ''
        reverse_proxy storage:4444
      '';
    };
    "seafile.${domain}" = {
      useACMEHost = domain;
      extraConfig = ''
        reverse_proxy storage:8082
      '';
    };
    "filestash.${domain}" = {
      useACMEHost = domain;
      extraConfig = ''
        reverse_proxy storage:8334
      '';
    };
    "filerun.${domain}" = {
      useACMEHost = domain;
      extraConfig = ''
        reverse_proxy storage:6000
      '';
    };
    "idm.${domain}" = {
      useACMEHost = domain;
      extraConfig = ''
        reverse_proxy https://storage:8443 {
          transport http {
            tls_insecure_skip_verify
          }
        }
      '';
    };
    "nextcloud.${domain}" = {
      useACMEHost = domain;
      extraConfig = ''
        rewrite /.well-known/carddav /remote.php/dav
        rewrite /.well-known/caldav /remote.php/dav

        reverse_proxy storage:8099
      '';
    };
  };
}
