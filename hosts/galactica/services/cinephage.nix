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
    # entrypoint chowns /app and /config: CHOWN; touches files owned by media: DAC_OVERRIDE, FOWNER; drops privileges: SETUID, SETGID (probe could not run it end to end).
    container.hardening.caps = ["CHOWN" "DAC_OVERRIDE" "FOWNER" "SETUID" "SETGID"];
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
