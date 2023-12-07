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
  generateHost = cfg: {
    "${cfg.name}.${domain}" = {
      useACMEHost = domain;
      extraConfig = "reverse_proxy ${cfg.host}:${cfg.port}";
    };
  };
  services = {
    cloud = {
      "vault" = "8000";
      "yarr" = "7070";
      "dev" = "8000";
      "invidious" = "3939";
      "ladder" = "8766";
      "actual" = "5006";
    };
    storage = {
      "minio" = "9000";
      "gitea" = "3001";
      "speedtest" = "8765";
      "photos" = "15777";
      "immich" = "15777";
      "duplicati" = "8200";
      "radarr" = "7878";
      "lidarr" = "8686";
      "jackett" = "9117";
      "sonarr" = "8989";
      "bazarr" = "6767";
      "whisparr" = "6969";
      "qbittorrent" = "8080";
      "transmission" = "9091";
      "qflood" = "3000";
      "prowlarr" = "9696";
      "flaresolverr" = "8191";
      "stash" = "9999";
      "netdata" = "19999";
      "remotely" = "5000";
      "tautulli" = "8181";
      "jellyfin" = "8096";
      "jf" = "3831";
      "nzbhydra2" = "5076";
      "sabnzbd" = "9998";
      "hass" = "8123";
      "grafana" = "2345";
      "seafile" = "8082";
      "filestash" = "8334";
      "filerun" = "6000";
      "restic" = "8000";
    };
  };
  configs = concatLists (mapAttrsToList (host: pairs: mapAttrsToList (name: port: {inherit name port host;}) pairs) services);
  hosts = foldl' (acc: host: acc // host) {} (map generateHost configs);
in {
  security.acme.certs."${domain}" = {
    extraDomainNames = ["*.${domain}"];
  };

  services.caddy.email = email;

  services.caddy.virtualHosts =
    hosts
    // {
      "code.${domain}" = {
        useACMEHost = domain;
        extraConfig = ''
          basicauth /* {
            admin $2a$14$oVkXE/xxSehMnluRIbEzyeCETY.ra1XGx3rCohBi1k/usv32CF2JS
          }

          reverse_proxy storage:3434
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
