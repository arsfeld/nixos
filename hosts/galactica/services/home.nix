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
      };
    };
  };
}
