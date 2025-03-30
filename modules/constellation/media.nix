{
  config,
  lib,
  ...
}: let
  cfg = config.constellation.media;
  vars = config.media.config;
in {
  options.constellation.media = {
    enable = lib.mkEnableOption "media";
  };

  config = lib.mkIf cfg.enable {
    media.gateway.insecureTls = ["nextcloud"];

    media.containers = let
      storageServices = {
        nextcloud = {
          listenPort = 443;
          volumes = [
            "${vars.storageDir}/files/Nextcloud:/data"
          ];
        };

        overseerr = {
          listenPort = 5055;
        };

        jackett = {
          listenPort = 9117;
        };

        bazarr = {
          listenPort = 6767;
          mediaVolumes = true;
        };

        radarr = {
          listenPort = 7878;
          mediaVolumes = true;
        };

        sonarr = {
          listenPort = 8989;
          mediaVolumes = true;
        };

        prowlarr = {
          listenPort = 9696;
        };

        autobrr = {
          image = "ghcr.io/autobrr/autobrr:latest";
          listenPort = 7474;
        };

        pinchflat = {
          image = "ghcr.io/kieraneglin/pinchflat:latest";
          listenPort = 8945;
          volumes = [
            "${vars.storageDir}/media/Pinchflat:/downloads"
          ];
        };

        plex = {
          environment = {
            VERSION = "latest";
          };
          mediaVolumes = true;
          network = "host";
          devices = ["/dev/dri:/dev/dri"];
        };

        stash = {
          image = "stashapp/stash:latest";
          configDir = "/root/.stash";
          mediaVolumes = true;
          network = "host";
          devices = ["/dev/dri:/dev/dri"];
        };

        flaresolverr = {
          image = "ghcr.io/flaresolverr/flaresolverr:latest";
          listenPort = 8191;
          exposePort = 8191;
          configDir = null;
        };

        kavita = {
          listenPort = 5000;
          volumes = [
            "${vars.storageDir}/media/Manga:/data"
          ];
        };
      };

      cloudServices = {
        ghost = {
          image = "ghost:5";
          volumes = ["/var/lib/ghost/content:/var/lib/ghost/content"];
          configDir = null;
          environment = {
            url = "https://blog.arsfeld.dev";
            database__client = "sqlite3";
            database__connection__filename = "/var/lib/ghost/content/data/ghost.db";
            database__useNullAsDefault = "true";
          };
          listenPort = 2368;
        };
      };

      # Apply the storage host to all services
      addHost = host: name: service: service // {host = host;};
    in
      lib.mapAttrs (addHost "storage") storageServices // lib.mapAttrs (addHost "cloud") cloudServices;
  };
}
