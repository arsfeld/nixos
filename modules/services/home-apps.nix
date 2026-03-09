# Home and utility apps: Audiobookshelf, Grocy, Stirling PDF, Actual Budget
{
  config,
  lib,
  self,
  ...
}: let
  cfg = config.constellation.homeApps;
  mkService = import "${self}/modules/media/__mkService.nix" {inherit lib;};
  vars = config.media.config;
in {
  options.constellation.homeApps.enable = lib.mkEnableOption "home and utility apps (Audiobookshelf, Grocy, Stirling, Actual)";

  config = lib.mkIf cfg.enable (lib.mkMerge [
    (mkService "audiobookshelf" {
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
      funnel = true;
      tailscaleExposed = true;
    })

    (mkService "grocy" {
      port = 80;
      image = "lscr.io/linuxserver/grocy:latest";
      container = {
        exposePort = 9283;
      };
      funnel = true;
      tailscaleExposed = true;
    })

    (mkService "stirling" {
      port = 8080;
      image = "frooodle/s-pdf:latest";
      container = {
        exposePort = 9284;
        configDir = "/configs";
      };
      funnel = true;
    })

    (mkService "actual" {
      port = 5006;
      image = "ghcr.io/actualbudget/actual-server:latest";
      container = {
        volumes = [
          "${vars.configDir}/actual:/data"
        ];
      };
      bypassAuth = true;
    })
  ]);
}
