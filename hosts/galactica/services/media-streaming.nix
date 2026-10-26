# Media streaming services: Jellyfin, Plex, Stash, Kavita
{
  config,
  lib,
  ...
}: let
  vars = config.media.config;
in {
  config = {
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
      # Probe-verified: root process writes /root/.stash owned by media (5000) and failed with EACCES without caps.
      # DAC_OVERRIDE: write dirs/files owned by another uid.
      # FOWNER: precautionary alongside DAC_OVERRIDE (not individually shown necessary).
      container.hardening.caps = ["DAC_OVERRIDE" "FOWNER"];
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
