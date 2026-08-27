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

    # FlareSolverr — solves Cloudflare challenges for indexers. Internal only
    # (no gateway entry): an unauthenticated FlareSolverr is an abusable proxy
    # — /v1 fetches any URL through this host's IP — so it is not exposed
    # publicly. Mirrors the same decision on pegasus (hosts/pegasus/services/
    # media.nix). Nothing reached it through the vhost: jackett has
    # FlareSolverrUrl = null, prowlarr has no reference, and mydia is
    # host-networked and uses http://localhost:8191 (media-apps.nix).
    #
    # port = null drops the gateway entry, so the host port has to be published
    # explicitly (the media.services contract for gateway-less containers).
    # Published on 0.0.0.0, not 127.0.0.1, so bridge containers like prowlarr
    # can still reach it at host.containers.internal:8191 if they ever need to;
    # the host firewall's 22/80/443 allowlist keeps it off the public internet.
    media.services.flaresolverr = {
      port = null;
      image = "ghcr.io/flaresolverr/flaresolverr:latest";
      container = {
        configDir = null;
        extraOptions = ["--publish=8191:8191"];
      };
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
