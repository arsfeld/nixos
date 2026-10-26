{
  config,
  lib,
  ...
}: {
  sops.secrets."finance-tracker-env" = {};

  media.services.home = {
    port = 8085;
    tailscaleExposed = true;
  };

  media.services.www = {
    port = 8085;
    tailscaleExposed = true;
  };

  media.services.finance-tracker = {
    # Probe-verified: root process writes its data dir owned by media (5000) and failed with EACCES without caps.
    # DAC_OVERRIDE: write dirs/files owned by another uid.
    # FOWNER: precautionary alongside DAC_OVERRIDE (not individually shown necessary).
    container.hardening.caps = ["DAC_OVERRIDE" "FOWNER"];
    port = 8080;
    image = "ghcr.io/arsfeld/finance-tracker:latest";
    watchImage = true;
    container = {
      environmentFiles = [
        config.sops.secrets."finance-tracker-env".path
        config.sops.secrets."ntfy-publisher-env".path
      ];
      environment = {
        SYNC_SCHEDULE = "0 0 17 */2 * *";
        # Disable email notifications while keeping ntfy.
        MAILER_URL = "";
        MAILER_FROM = "";
        MAILER_TO = "";
      };
    };
  };
}
