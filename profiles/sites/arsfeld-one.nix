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
  bypassAuth = ["auth" "transmission" "flaresolverr" "attic" "dns" "search" "immich" "sudo-proxy"];
  cors = ["sudo-proxy"];
  generateHost = cfg: {
    "${cfg.name}.${domain}" = {
      useACMEHost = domain;
      extraConfig =
        (
          if builtins.elem cfg.name bypassAuth
          then ""
          else ''
            forward_auth cloud:9099 {
              uri /api/verify?rd=https://auth.${domain}/
              copy_headers Remote-User Remote-Groups Remote-Name Remote-Email
            }
          ''
        )
        + (
          if builtins.elem cfg.name cors
          then ""
          else ''
            import cors {header.origin}
          ''
        )
        + ''
          reverse_proxy ${cfg.host}:${toString cfg.port}
        '';
    };
  };
  services = {
    cloud = {
      vault = 8000;
      yarr = 7070;
      dev = 8000;
      invidious = 3939;
      ladder = 8766;
      actual = 5006;
      users = 17170;
      dns = 4000;
      attic = 8080;
      #"auth" = "9099";
      search = 8888;
      metube = 8081;
      sudo-proxy = 3030;
    };
    storage = {
      code = 3434;
      resilio = 9000;
      gitea = 3001;
      speedtest = 8765;
      photos = 2342;
      photoprism = 2342;
      immich = 15777;
      duplicati = 8200;
      radarr = 7878;
      lidarr = 8686;
      jackett = 9117;
      sonarr = 8989;
      bazarr = 6767;
      overseer = 5055;
      whisparr = 6969;
      grocy = 9283;
      qbittorrent = 8080;
      transmission = 9091;
      prowlarr = 9696;
      stash = 9999;
      netdata = 19999;
      remotely = 5000;
      tautulli = 8181;
      jellyfin = 8096;
      jf = 3831;
      nzbhydra2 = 5076;
      sabnzbd = 8080;
      grafana = 2345;
      seafile = 8082;
      filestash = 8334;
      filerun = 6000;
      restic = 8000;
      stirling = 9284;
      syncthing = 8384;
      flaresolverr = 8191;
      scrutiny = 9998;
      pinchflat = 8945;
    };
    r2s = {
      hass = 8123;
    };
  };
  configs = concatLists (mapAttrsToList (host: pairs: mapAttrsToList (name: port: {inherit name port host;}) pairs) services);
  hosts = foldl' (acc: host: acc // host) {} (map generateHost configs);
in {
  security.acme.certs."${domain}" = {
    extraDomainNames = ["*.${domain}"];
  };

  services.caddy.email = email;

  services.caddy.extraConfig = ''
    (cors) {
      @cors_preflight method OPTIONS

      header {
        Access-Control-Allow-Origin "{header.origin}"
        Vary Origin
        Access-Control-Expose-Headers "Authorization"
        Access-Control-Allow-Credentials "true"
      }

      handle @cors_preflight {
        header {
          Access-Control-Allow-Methods "GET, POST, PUT, PATCH, DELETE"
          Access-Control-Max-Age "3600"
        }
        respond "" 204
      }
    }
  '';

  services.caddy.virtualHosts =
    hosts
    // {
      "auth.${domain}" = {
        useACMEHost = domain;
        extraConfig = "reverse_proxy cloud:9099";
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
