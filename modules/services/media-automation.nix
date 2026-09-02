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
    # media.nix).
    #
    # Every client reaches it internally, never through a vhost: mydia is
    # host-networked on http://localhost:8191 (media-apps.nix), and prowlarr's
    # FlareSolverr indexer proxy points at http://host.containers.internal:8191/.
    # jackett has FlareSolverrUrl = null. Prowlarr's is the one to remember:
    # it lives in prowlarr.db, not in this repo, so grepping here shows no
    # reference and dropping the vhost (2026-08-27) looked safe. It was not —
    # the proxy still pointed at https://flaresolverr.arsfeld.one/, every
    # Cloudflare-gated indexer started failing on a 404, and it was repointed
    # to the internal endpoint on 2026-09-01. Same caveat as transmission: a
    # restore from a backup predating that reintroduces the dead URL.
    #
    # port = null drops the gateway entry, so the host port has to be published
    # explicitly (the media.services contract for gateway-less containers).
    # Published on 0.0.0.0, not 127.0.0.1, so bridge containers like prowlarr
    # can reach it at host.containers.internal:8191; the host firewall's
    # 22/80/443 allowlist keeps it off the public internet.
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
