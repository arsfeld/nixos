{
  lib,
  config,
  ...
}:
with lib; let
  domain = "arsfeld.one";
  email = "arsfeld@gmail.com";
  bypassAuth = [
    "attic"
    "auth"
    "auth"
    "dns"
    "flaresolverr"
    "grafana"
    "immich"
    "nextcloud"
    "search"
    "sudo-proxy"
    "transmission"
    "vault"
  ];
  cors = ["sudo-proxy"];
  funnels = ["yarr" "jellyfin"];

  services = {
    cloud = {
      actual = 5006;
      attic = 8080;
      auth = 9099;
      dev = 8000;
      dns = 4000;
      invidious = 3939;
      ladder = 8766;
      metube = 8081;
      search = 8888;
      sudo-proxy = 3030;
      users = 17170;
      vault = 8000;
      yarr = 7070;
      whoogle = 5000;
    };
    storage = {
      bazarr = 6767;
      beszel = 8090;
      bitmagnet = 3333;
      code = 3434;
      duplicati = 8200;
      fileflows = 19200;
      filerun = 6000;
      filestash = 8334;
      flaresolverr = 8191;
      gitea = 3001;
      grafana = 3010;
      grocy = 9283;
      hass = 8123;
      headphones = 8787;
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
      plex = 32400;
      prowlarr = 9696;
      qbittorrent = 8999;
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
      threadfin = 34400;
      transmission = 9091;
      whisparr = 6969;
      www = 8085;
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
          import errors
          reverse_proxy ${cfg.host}:${toString cfg.port} {
            @error status 404 500 503
            handle_response @error {
              error {rp.status_code}
            }
          }

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

  services.caddy.globalConfig = ''
    servers {
      max_header_size 5MB
    }
  '';

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

    (errors) {
      handle_errors {
        rewrite * /error-pages/l7/{err.status_code}.html
        reverse_proxy https://tarampampam.github.io {
          header_up Host {upstream_hostport}
          replace_status {err.status_code}
        }
      }
    }

    *.${domain} {
      import errors
      error 404
    }

    ${domain} {
      redir https://www.{host}{uri}
    }
  '';

  services.caddy.virtualHosts =
    hosts
    // {
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
