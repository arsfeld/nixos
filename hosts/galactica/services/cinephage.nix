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
    # Not fully probe-verified: the control run cannot start in isolation (it downloads Camoufox), so the verdict was INCONCLUSIVE.
    # Evidence is from hardened-run log lines (raw lines are in task-5-report.md), not a control-vs-hardened comparison.
    # DAC_OVERRIDE: the no-caps hardened run logged "mkdir: cannot create directory '/config/cache': Permission denied" (/config is owned by media).
    # CHOWN: the hardened run with only DAC_OVERRIDE and FOWNER logged "chown: changing ownership of '/app/build/client/...': Operation not permitted".
    # FOWNER: precautionary alongside DAC_OVERRIDE.
    # SETUID, SETGID: precautionary (the entrypoint appears to drop to PUID; the drop was not observed).
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
