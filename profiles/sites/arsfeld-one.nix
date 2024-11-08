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
  bypassAuth = ["auth" "transmission" "flaresolverr" "attic" "dns" "search" "immich" "sudo-proxy" "vault"];
  cors = ["sudo-proxy"];
  funnels = ["romm" "yarr"];

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
      bazarr = 6767;
      code = 3434;
      duplicati = 8200;
      filerun = 6000;
      filestash = 8334;
      flaresolverr = 8191;
      gitea = 3001;
      grafana = 2345;
      grocy = 9283;
      immich = 15777;
      jackett = 9117;
      jellyfin = 8096;
      jf = 3831;
      lidarr = 8686;
      netdata = 19999;
      nzbhydra2 = 5076;
      overseer = 5055;
      photoprism = 2342;
      photos = 2342;
      pinchflat = 8945;
      prowlarr = 9696;
      qbittorrent = 8080;
      radarr = 7878;
      remotely = 5000;
      resilio = 9000;
      restic = 8000;
      romm = 8998;
      sabnzbd = 8080;
      scrutiny = 9998;
      seafile = 8082;
      sonarr = 8989;
      speedtest = 8765;
      stash = 9999;
      stirling = 9284;
      syncthing = 8384;
      tautulli = 8181;
      transmission = 9091;
      whisparr = 6969;
    };
    r2s = {
      hass = 8123;
    };
  };
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
  generateService = cfg:
    if (config.networking.hostName == cfg.host)
    then {
      "${cfg.name}" = {
        toURL = "http://127.0.0.1:${toString cfg.port}";
        funnel = builtins.elem cfg.name funnels;
      };
    }
    else {};
  configs = concatLists (mapAttrsToList (host: pairs: mapAttrsToList (name: port: {inherit name port host;}) pairs) services);
  tsnsrvConfigs = foldl' (acc: host: acc // host) {} (map generateService configs);
  hosts = foldl' (acc: host: acc // host) {} (map generateHost configs);
in {
  security.acme.certs."${domain}" = {
    extraDomainNames = ["*.${domain}"];
  };

  services.tsnsrv.services = tsnsrvConfigs;

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
