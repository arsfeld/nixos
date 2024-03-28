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
      extraConfig = ''
        forward_auth cloud:9099 {
          uri /api/verify?rd=https://auth.${domain}/
          copy_headers Remote-User Remote-Groups Remote-Name Remote-Email
        }
        reverse_proxy ${cfg.host}:${cfg.port}
      '';
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
      "users" = "17170";
    };
    storage = {
      "code" = "3434";
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
      "overseer" = "5055";
      "whisparr" = "6969";
      "grocy" = "9283";
      "qbittorrent" = "8080";
      #"transmission" = "9091";
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
      "grafana" = "2345";
      "seafile" = "8082";
      "filestash" = "8334";
      "filerun" = "6000";
      "restic" = "8000";
      "stirling" = "9284";
      "syncthing" = "8384";
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
      "auth.${domain}" = {
        useACMEHost = domain;
        extraConfig = "reverse_proxy cloud:9099";
      };
      "transmission.${domain}" = {
        useACMEHost = domain;
        extraConfig = "reverse_proxy storage:9091";
      };
      "hass.${domain}" = {
        useACMEHost = domain;
        extraConfig = "reverse_proxy r2s:8123";
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
