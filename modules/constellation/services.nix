# Constellation services gateway module
#
# This module manages the service registry and gateway configuration for all
# Constellation services. It provides a centralized definition of services,
# their ports, authentication requirements, and routing rules.
#
# Key features:
# - Centralized service registry with host assignments and ports
# - Authentication bypass configuration for services with built-in auth
# - CORS support for services requiring cross-origin requests
# - Tailscale Funnel configuration for public access to select services
# - Automatic gateway configuration generation
# - Service discovery and routing across multiple hosts
#
# Services are organized by host:
# - Cloud host: Public-facing services (auth, DNS, messaging, etc.)
# - Storage host: Media servers, home automation, development tools
#
# The module integrates with the media.gateway system to provide unified
# access control and routing for all services through a single entry point.
{
  lib,
  config,
  ...
}:
with lib; let
  services = {
    cloud = {
      auth = null;
      dex = null;
      dns = null;
      invidious = null;
      metube = null;
      mqtt = 1883;
      ntfy = null;
      owntracks = 8083;
      owntracks-ui = 8084;
      search = null;
      users = null;
      vault = 8000;
      whoogle = 5000;
      yarr = 7070;
    };
    storage = {
      attic = 8080;
      audiobookshelf = 13378;
      # beszel = 8090; # Disabled - monitoring service causing high CPU usage
      bitmagnet = 3333;
      code = 4444;
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
      nextcloud = 8099;
      ollama-api = 11434;
      ollama = 30198;
      openarchiver = 3000;
      photoprism = 2342;
      photos = 2342;
      plex = 32400;
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
      yarr-dev = 7070;
    };
    raider = {
      harmonia = 5000;
    };
  };

  bypassAuth = [
    "attic"
    "audiobookshelf"
    "auth"
    "autobrr"
    "dns"
    "flaresolverr"
    "grafana"
    "ghost"
    "harmonia"
    "immich"
    "jellyfin"
    "mqtt"
    "nextcloud"
    "ntfy"
    "ollama-api"
    "openarchiver"
    "owntracks"
    "owntracks-ui"
    "qbittorrent"
    "search"
    "sudo-proxy"
    "transmission"
    "vault"
  ];

  cors = ["sudo-proxy"];

  # Services that should be publicly accessible via Tailscale Funnel (*.bat-boa.ts.net)
  # When a service is in this list, its bat-boa.ts.net domain is accessible from the public internet
  # When NOT in this list (but in tailscaleExposed), bat-boa.ts.net is only accessible within the tailnet
  # Note: This does NOT affect arsfeld.one access - ALL services are accessible via *.arsfeld.one through cloud gateway
  funnels = [
    "attic"
    "audiobookshelf"
    "yarr"
    "jellyfin"
    "yarr-dev"
    "plex"
    "immich"
    "photos"
    "photoprism"
    "home"
    "hass"
    "grocy"
    "ntfy"
    "gitea"
    "code"
    "n8n"
    "netdata"
    "grafana"
    "filebrowser"
    "filerun"
    "filestash"
    "mqtt"
    "owntracks"
    "owntracks-ui"
    "seafile"
    "syncthing"
    "resilio"
    "search"
    "invidious"
    "whoogle"
    "romm"
    "komga"
    "stirling"
    "windmill"
    "beszel"
    "speedtest"
    "scrutiny"
    "stash"
  ];

  # Services that should have dedicated Tailscale nodes (*.bat-boa.ts.net access) via tsnsrv
  # Services in this list get their own service.bat-boa.ts.net hostname for direct tailnet access
  # Services NOT in this list are only accessible via *.arsfeld.one (no bat-boa.ts.net hostname)
  # Note: ALL services (whether in this list or not) are accessible via *.arsfeld.one through cloud gateway
  # This list is kept minimal to reduce CPU overhead from tsnsrv instances (task-49)
  # Only frequently accessed services are exposed via Tailscale
  # Note: Cloud-based services (auth, dex, dns, users) are excluded because:
  #   1. They run on cloud host which doesn't have tsnsrv enabled
  #   2. They're accessed via cloud.bat-boa.ts.net, not individual nodes
  #   3. Storage host accesses them via cloud gateway
  tailscaleExposed = [
    "jellyfin"
    "plex"
    "immich"
    "photos"
    "audiobookshelf"
    "hass"
    "grocy"
    "home"
    "harmonia"
    "www"
    "code"
    "gitea"
    "n8n"
    "grafana"
    "netdata"
    "stash"
  ];

  # generateServices: Transforms nested service definitions into a flat list of configs
  # Input: generateServices { storage = { jellyfin = null; }; cloud = { yarr = 8096; } }
  # Output: {"jellyfin" = { name = "jellyfin"; host = "storage"; exposeViaTailscale = true; }; "yarr" = { name = "yarr"; host = "cloud"; port = 8096; exposeViaTailscale = false; }}
  generateServices = services:
    listToAttrs (builtins.concatMap
      (host:
        builtins.map
        (name: {
          inherit name;
          value =
            {
              inherit name host;
              exposeViaTailscale = builtins.elem name tailscaleExposed;
              settings = mkDefault {
                bypassAuth = builtins.elem name bypassAuth;
                cors = builtins.elem name cors;
                funnel = builtins.elem name funnels;
              };
            }
            // (
              if services.${host}.${name} != null
              then {port = services.${host}.${name};}
              else {}
            );
        })
        (builtins.attrNames services.${host}))
      (builtins.attrNames services));
in {
  options.constellation.services = {
    enable = lib.mkOption {
      type = lib.types.bool;
      description = ''
        Enable the Constellation services gateway configuration.
        This sets up service discovery, routing, and authentication
        for all services across the infrastructure.
      '';
      default = false;
    };
  };

  config = lib.mkIf config.constellation.services.enable {
    media.gateway = {
      enable = true;

      authHost = "cloud.bat-boa.ts.net";
      authPort = config.media.gateway.services.auth.port;

      services = generateServices services;
    };
  };
}
