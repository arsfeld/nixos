# Media automation services: *arr stack, Autobrr, Flaresolverr, Pinchflat
{
  config,
  lib,
  self,
  ...
}: let
  cfg = config.constellation.mediaAutomation;
  mkService = import "${self}/modules/media/__mkService.nix" {inherit lib;};
  vars = config.media.config;
in {
  options.constellation.mediaAutomation.enable = lib.mkEnableOption "media automation services (Radarr, Sonarr, Bazarr, Prowlarr, etc.)";

  config = lib.mkIf cfg.enable (lib.mkMerge [
    (mkService "radarr" {
      port = 7878;
      container = {
        mediaVolumes = true;
      };
    })

    (mkService "sonarr" {
      port = 8989;
      container = {
        mediaVolumes = true;
      };
    })

    (mkService "bazarr" {
      port = 6767;
      container = {
        mediaVolumes = true;
      };
      bypassAuth = true;
    })

    (mkService "prowlarr" {
      port = 9696;
      container = {
        exposePort = 9696;
      };
      bypassAuth = true;
    })

    (mkService "jackett" {
      port = 9117;
      container = {};
      bypassAuth = true;
    })

    (mkService "autobrr" {
      port = 7474;
      image = "ghcr.io/autobrr/autobrr:latest";
      container = {};
      bypassAuth = true;
    })

    (mkService "overseerr" {
      port = 5055;
      container = {};
      bypassAuth = true;
    })

    (mkService "flaresolverr" {
      port = 8191;
      image = "ghcr.io/flaresolverr/flaresolverr:latest";
      container = {
        exposePort = 8191;
        configDir = null;
      };
      bypassAuth = true;
    })

    (mkService "pinchflat" {
      port = 8945;
      image = "ghcr.io/kieraneglin/pinchflat:latest";
      container = {
        volumes = [
          "${vars.storageDir}/media/Pinchflat:/downloads"
        ];
      };
      bypassAuth = true;
    })
  ]);
}
