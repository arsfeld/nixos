# Home and utility apps: Audiobookshelf, Grocy, Stirling PDF, Actual Budget
{
  config,
  lib,
  ...
}: let
  cfg = config.constellation.homeApps;
  vars = config.media.config;
in {
  options.constellation.homeApps.enable = lib.mkEnableOption "home and utility apps (Audiobookshelf, Grocy, Stirling, Actual)";

  config = lib.mkIf cfg.enable {
    media.services.audiobookshelf = {
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

    media.services.grocy = {
      port = 80;
      image = "lscr.io/linuxserver/grocy:latest";
      container = {
        exposePort = 9283;
      };
      tailscaleExposed = true;
    };

    media.services.stirling = {
      port = 8080;
      image = "frooodle/s-pdf:latest";
      container = {
        exposePort = 9284;
        configDir = "/configs";
      };
    };

    media.services.actual = {
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
