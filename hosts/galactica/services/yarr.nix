{
  config,
  lib,
  ...
}: {
  sops.secrets."yarr-env" = {};

  media.services.yarr = {
    port = 7070;
    image = "ghcr.io/arsfeld/yarr:master";
    tailscaleExposed = true;
    container = {
      exposePort = 7070;
      configDir = "/data";
      environmentFiles = [
        config.sops.secrets."yarr-env".path
      ];
    };
  };
}
