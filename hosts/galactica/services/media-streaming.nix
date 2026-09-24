# Media streaming services: Jellyfin, Plex, Stash, Kavita
{
  config,
  lib,
  ...
}: let
  cfg = config.constellation.mediaStreaming;
  vars = config.media.config;
in {
  options.constellation.mediaStreaming.enable = lib.mkEnableOption "media streaming services (Plex, Jellyfin, Stash, Kavita)";

  config = lib.mkIf cfg.enable {
    media.services.jellyfin = {
      port = 8096;
      container = {
        exposePort = 8096;
        mediaVolumes = true;
        devices = ["/dev/dri:/dev/dri"];
        environment = {
          JELLYFIN_PublishedServerUrl = "https://jellyfin.arsfeld.one";
        };
      };
      bypassAuth = true;
      tailscaleExposed = true;
    };

    media.services.plex = {
      port = 32400;
      container = {
        exposePort = 32400;
        mediaVolumes = true;
        network = "host";
        devices = ["/dev/dri:/dev/dri"];
        environment.VERSION = "latest";
      };
      tailscaleExposed = true;
    };

    media.services.stash = {
      port = 9999;
      image = "stashapp/stash:latest";
      container = {
        exposePort = 9999;
        configDir = "/root/.stash";
        mediaVolumes = true;
        network = "host";
        devices = ["/dev/dri:/dev/dri"];
      };
      tailscaleExposed = true;
    };

    media.services.kavita = {
      port = 5000;
      container = {
        volumes = [
          "${vars.storageDir}/media/Manga:/data"
        ];
      };
      bypassAuth = true;
    };
  };
}
