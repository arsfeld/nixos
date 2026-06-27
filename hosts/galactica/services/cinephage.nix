{
  config,
  lib,
  ...
}: let
  vars = config.media.config;
  url = "https://cinephage.${vars.domain}";
in {
  sops.secrets."cinephage-env" = {};

  media.services.cinephage = {
    port = 3000;
    image = "ghcr.io/moldytaint/cinephage:latest";
    bypassAuth = true;
    tailscaleExposed = true;
    container = {
      mediaVolumes = true;
      volumes = [
        "${vars.storageDir}/media/Downloads:/downloads"
      ];
      environmentFiles = [
        config.sops.secrets."cinephage-env".path
      ];
      environment = {
        BETTER_AUTH_URL = url;
        ORIGIN = url;
        PUBLIC_BASE_URL = url;
      };
    };
  };
}
