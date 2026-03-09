# Media streaming services: Jellyfin, Plex, Stash, Kavita
{
  config,
  lib,
  self,
  ...
}: let
  cfg = config.constellation.mediaStreaming;
  mkService = import "${self}/modules/media/__mkService.nix" {inherit lib;};
  vars = config.media.config;
in {
  options.constellation.mediaStreaming.enable = lib.mkEnableOption "media streaming services (Plex, Jellyfin, Stash, Kavita)";

  config = lib.mkIf cfg.enable (lib.mkMerge [
    (mkService "jellyfin" {
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
      funnel = true;
      tailscaleExposed = true;
    })

    (mkService "plex" {
      port = 32400;
      container = {
        exposePort = 32400;
        mediaVolumes = true;
        network = "host";
        devices = ["/dev/dri:/dev/dri"];
        environment.VERSION = "latest";
      };
      funnel = true;
      tailscaleExposed = true;
    })

    (mkService "stash" {
      port = 9999;
      image = "stashapp/stash:latest";
      container = {
        exposePort = 9999;
        configDir = "/root/.stash";
        mediaVolumes = true;
        network = "host";
        devices = ["/dev/dri:/dev/dri"];
      };
      funnel = true;
      tailscaleExposed = true;
    })

    (mkService "kavita" {
      port = 5000;
      container = {
        volumes = [
          "${vars.storageDir}/media/Manga:/data"
        ];
      };
      bypassAuth = true;
    })
  ]);
}
