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
    # Not probe-verified (the probe could not run it without secrets/DB); caps come from the image's entrypoint.
    # CHOWN: observed in probe output: 'chown: changing ownership of /app/build/client/...: Operation not permitted' when dropped.
    # DAC_OVERRIDE: its /config is owned by media; 'mkdir /config/cache: Permission denied' seen without it.
    # FOWNER: precautionary alongside DAC_OVERRIDE.
    # SETUID, SETGID: precautionary (entrypoint appears to drop to PUID; the drop was not observed).
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
