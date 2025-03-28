{
  self,
  lib,
  config,
  ...
}: let
  nameToPort = import "${self}/common/nameToPort.nix";

  # Helper function to process a set and replace null values with generated ports
  processServices = serviceSet:
    builtins.mapAttrs (
      name: value:
        if value == null
        then nameToPort name
        else value
    )
    serviceSet;

  services = {
    cloud = processServices {
      auth = null;
      dex = null;
      dns = null;
      invidious = null;
      metube = null;
      ntfy = null;
      search = null;
      users = null;
      vault = 8000;
      whoogle = 5000;
      yarr = 7070;
    };
    storage = processServices {
      beszel = 8090;
      bitmagnet = 3333;
      code = 3434;
      duplicati = 8200;
      fileflows = 19200;
      filerun = 6000;
      filestash = 8334;
      filebrowser = 38080;
      gitea = 3001;
      grafana = 3010;
      grocy = 9283;
      hass = 8123;
      headphones = 8787;
      home = 8085;
      immich = 15777;
      jellyfin = 8096;
      jf = 3831;
      lidarr = 8686;
      komga = null;
      n8n = 5678;
      netdata = 19999;
      ollama-api = 11434;
      ollama = 30198;
      photoprism = 2342;
      photos = 2342;
      plex = 32400;
      qbittorrent = 8999;
      remotely = 5000;
      resilio = 9000;
      restic = 8000;
      romm = 8998;
      sabnzbd = 8080;
      scrutiny = 9998;
      seafile = 8082;
      speedtest = 8765;
      stash = 9999;
      stirling = 9284;
      syncthing = 8384;
      tautulli = 8181;
      threadfin = 34400;
      transmission = 9091;
      whisparr = 6969;
      www = 8085;
      windmill = 8001;
    };
  };
in {
  options.constellation.services = {
    enable = lib.mkEnableOption "constellation services";
  };

  config = lib.mkIf config.constellation.services.enable {
    media.gateway = {
      enable = true;

      authHost = "cloud.bat-boa.ts.net";
      authPort = services.cloud.auth;

      services = services;

      ports = services.cloud // services.storage;

      bypassAuth = [
        "auth"
        "autobrr"
        "dns"
        "flaresolverr"
        "grafana"
        "ghost"
        "immich"
        "nextcloud"
        "ntfy"
        "ollama-api"
        "search"
        "sudo-proxy"
        "transmission"
        "vault"
      ];

      cors = ["sudo-proxy"];

      funnels = ["yarr" "jellyfin"];
    };
  };
}
