# Home and utility apps: Audiobookshelf, Stirling PDF, Actual Budget
{
  config,
  lib,
  ...
}: let
  vars = config.media.config;
in {
  config = {
    media.services.audiobookshelf = {
      # root process writes /config and /metadata owned by media: DAC_OVERRIDE, FOWNER; listens on port 80 in-container: NET_BIND_SERVICE.
      container.hardening.caps = ["DAC_OVERRIDE" "FOWNER" "NET_BIND_SERVICE"];
      port = 80;
      image = "ghcr.io/advplyr/audiobookshelf:latest";
      container = {
        exposePort = 13378;
        configDir = null;
        volumes = [
          "${vars.configDir}/audiobookshelf/config:/config"
          "${vars.configDir}/audiobookshelf/metadata:/metadata"
          "${vars.dataDir}/media/audiobooks:/audiobooks"
          "${vars.dataDir}/media/podcasts:/podcasts"
        ];
        extraOptions = [
          "--label"
          "io.containers.autoupdate=image"
        ];
      };
      bypassAuth = true;
      tailscaleExposed = true;
    };

    media.services.stirling = {
      # entrypoint chowns its dirs: CHOWN; writes /configs owned by media: DAC_OVERRIDE, FOWNER; drops to a service user: SETUID, SETGID.
      container.hardening.caps = ["CHOWN" "DAC_OVERRIDE" "FOWNER" "SETUID" "SETGID"];
      port = 8080;
      image = "frooodle/s-pdf:latest";
      container = {
        exposePort = 9284;
        configDir = "/configs";
      };
    };

    media.services.actual = {
      # root process writes /data owned by media: DAC_OVERRIDE (mkdir/write), FOWNER (chmod/utimes).
      container.hardening.caps = ["DAC_OVERRIDE" "FOWNER"];
      port = 5006;
      image = "ghcr.io/actualbudget/actual-server:latest";
      container = {
        volumes = [
          "${vars.configDir}/actual:/data"
        ];
      };
      bypassAuth = true;
    };
  };
}
