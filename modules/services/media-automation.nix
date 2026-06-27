# Media automation services: *arr stack, Autobrr, Flaresolverr, Pinchflat
{
  config,
  lib,
  ...
}: let
  cfg = config.constellation.mediaAutomation;
  vars = config.media.config;
in {
  options.constellation.mediaAutomation.enable = lib.mkEnableOption "media automation services (Radarr, Sonarr, Bazarr, Prowlarr, etc.)";

  config = lib.mkIf cfg.enable {
    media.services.radarr = {
      port = 7878;
      container = {
        mediaVolumes = true;
      };
    };

    media.services.sonarr = {
      port = 8989;
      container = {
        mediaVolumes = true;
      };
    };

    media.services.bazarr = {
      port = 6767;
      container = {
        mediaVolumes = true;
      };
      bypassAuth = true;
    };

    media.services.prowlarr = {
      port = 9696;
      container = {
        exposePort = 9696;
      };
      bypassAuth = true;
    };

    media.services.jackett = {
      port = 9117;
      container = {};
      bypassAuth = true;
    };

    media.services.autobrr = {
      port = 7474;
      image = "ghcr.io/autobrr/autobrr:latest";
      container = {};
      bypassAuth = true;
    };

    media.services.overseerr = {
      port = 5055;
      container = {};
      bypassAuth = true;
    };

    media.services.flaresolverr = {
      port = 8191;
      image = "ghcr.io/flaresolverr/flaresolverr:latest";
      container = {
        exposePort = 8191;
        configDir = null;
      };
      bypassAuth = true;
    };

    media.services.pinchflat = {
      port = 8945;
      image = "ghcr.io/kieraneglin/pinchflat:latest";
      container = {
        volumes = [
          "${vars.storageDir}/media/Pinchflat:/downloads"
        ];
      };
      bypassAuth = true;
    };
  };
}
