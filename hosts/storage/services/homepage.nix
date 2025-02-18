{
  self,
  lib,
  config,
  pkgs,
  ...
}: let
  vars = config.mediaServices;
in {
  age.secrets.homepage-env.file = "${self}/secrets/homepage-env.age";

  services.homepage-dashboard = {
    enable = true;
    listenPort = 8085;
    environmentFile = config.age.secrets.homepage-env.path;
    widgets = [
      {
        resources = {
          cpu = true;
          memory = true;
          disk = ["/mnt/storage"];
        };
      }
      {
        openmeteo = {
          label = "Rouyn-Noranda";
          timezone = "America/Toronto";
          latitude = "48.2366";
          longitude = "-79.0231";
          units = "metric";
        };
      }
      {
        search = {
          provider = "custom";
          url = "https://www.startpage.com/do/dsearch?q=";
          target = "_blank";
        };
      }
    ];
    settings = {
      title = "Storage";
      headerStyle = "clean";
      layout = {
        media = {
          style = "row";
          columns = 3;
        };
        infra = {
          style = "row";
          columns = 4;
        };
        machines = {
          style = "row";
          columns = 4;
        };
      };
    };
    services = [
      {
        media = [
          {
            Plex = {
              icon = "plex.png";
              href = "https://plex.${vars.domain}";
              description = "Watch movies and TV shows.";
              server = "localhost";
              container = "plex";
              widget = {
                type = "tautulli";
                url = "https://tautulli.${vars.tsDomain}";
                key = "{{HOMEPAGE_VAR_TAUTULLI_KEY}}";
              };
            };
          }
          {
            Transmission = {
              icon = "transmission.png";
              href = "https://transmission.${vars.domain}";
              description = "torrent";
              widget = {
                type = "transmission";
                url = "https://transmission.${vars.tsDomain}";
                username = "{{HOMEPAGE_VAR_TRANSMISSION_USERNAME}}";
                password = "{{HOMEPAGE_VAR_TRANSMISSION_PASSWORD}}";
                rpcUrl = "/transmission/";
              };
            };
          }
          {
            Radarr = {
              icon = "radarr.png";
              href = "https://radarr.${vars.domain}";
              description = "film management";
              widget = {
                type = "radarr";
                url = "https://radarr.${vars.tsDomain}";
                key = "{{HOMEPAGE_VAR_RADARR_KEY}}";
              };
            };
          }
          {
            Sonarr = {
              icon = "sonarr.png";
              href = "https://sonarr.${vars.domain}";
              description = "tv management";
              widget = {
                type = "sonarr";
                url = "https://sonarr.${vars.tsDomain}";
                key = "{{HOMEPAGE_VAR_SONARR_KEY}}";
              };
            };
          }
          {
            Prowlarr = {
              icon = "prowlarr.png";
              href = "https://prowlarr.${vars.domain}";
              description = "index management";
              widget = {
                type = "prowlarr";
                url = "https://prowlarr.${vars.tsDomain}";
                key = "{{HOMEPAGE_VAR_PROWLARR_KEY}}";
              };
            };
          }
        ];
      }
    ];
  };
}
