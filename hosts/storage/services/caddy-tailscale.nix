# Caddy Tailscale gateway configuration for storage host
#
# This replaces the numerous tsnsrv processes with a single Caddy instance,
# providing significant resource savings and simplified management.
{
  config,
  lib,
  ...
}: let
  # Get port numbers from the nameToPort mapping
  nameToPort = import ../../../common/nameToPort.nix;
in {
  # Enable the new Caddy Tailscale gateway
  constellation.caddyTailscale = {
    enable = true;

    # Start with a subset of services for testing
    services = {
      # Internal services (no funnel, no auth needed for Tailnet users)
      autobrr = {
        port = nameToPort "autobrr";
        auth = "none";
        funnel = false;
      };

      bazarr = {
        port = nameToPort "bazarr";
        auth = "none";
        funnel = false;
      };

      sonarr = {
        port = nameToPort "sonarr";
        auth = "none";
        funnel = false;
      };

      radarr = {
        port = nameToPort "radarr";
        auth = "none";
        funnel = false;
      };

      prowlarr = {
        port = nameToPort "prowlarr";
        auth = "none";
        funnel = false;
      };

      # Mixed services (funnel enabled, auth for external traffic only)
      jellyfin = {
        port = 8096;
        auth = "external";
        funnel = true;
      };

      immich = {
        port = 2283;
        auth = "external";
        funnel = true;
      };

      filebrowser = {
        port = 38080;
        auth = "external";
        funnel = true;
      };

      nextcloud = {
        port = nameToPort "nextcloud";
        auth = "external";
        funnel = true;
      };

      # Services with their own authentication
      gitea = {
        port = 3001;
        auth = "none";
        funnel = true;
      };

      grafana = {
        port = 3010;
        auth = "none";
        funnel = true;
      };

      home-assistant = {
        port = 8123;
        auth = "none";
        funnel = true;
      };

      # Plex (special case - uses host networking)
      plex = {
        port = 32400;
        auth = "none";
        funnel = true;
      };

      # Additional services from misc.nix
      romm = {
        port = 8998;
        auth = "external";
        funnel = true;
      };

      speedtest = {
        port = 8765;
        auth = "external";
        funnel = true;
      };

      syncthing = {
        port = 8384;
        auth = "external";
        funnel = true;
      };

      webdav = {
        port = 4918;
        auth = "none";
        funnel = false;
      };

      # Media services
      overseerr = {
        port = nameToPort "overseerr";
        auth = "external";
        funnel = true;
      };

      jackett = {
        port = nameToPort "jackett";
        auth = "external";
        funnel = false;
      };

      kavita = {
        port = nameToPort "kavita";
        auth = "external";
        funnel = true;
      };

      actual = {
        port = nameToPort "actual";
        auth = "external";
        funnel = true;
      };

      # Homepage dashboard
      homepage = {
        port = 3000;
        auth = "none";
        funnel = true;
      };

      # Code server
      code = {
        port = 8080;
        auth = "external";
        funnel = true;
      };

      # Netdata monitoring
      netdata = {
        port = 19999;
        auth = "external";
        funnel = true;
      };

      # qBittorrent
      qbittorrent = {
        port = nameToPort "qbittorrent";
        auth = "external";
        funnel = true;
      };

      # Seafile
      seafile = {
        port = 8000;
        auth = "external";
        funnel = true;
      };

      # Komga
      komga = {
        port = nameToPort "komga";
        auth = "external";
        funnel = true;
      };

      # SABnzbd
      sabnzbd = {
        port = nameToPort "sabnzbd";
        auth = "external";
        funnel = true;
      };

      # Grocy
      grocy = {
        port = nameToPort "grocy";
        auth = "external";
        funnel = true;
      };

      # Filestash
      filestash = {
        port = 8334;
        auth = "external";
        funnel = true;
      };

      # Filerun
      filerun = {
        port = nameToPort "filerun";
        auth = "external";
        funnel = true;
      };

      # PhotoPrism
      photos = {
        port = 2342;
        auth = "external";
        funnel = true;
      };
    };
  };

  # Temporarily disable the old tsnsrv services to avoid conflicts
  # Once testing is complete, this can be removed permanently
  services.tsnsrv.enable = lib.mkForce false;
}
