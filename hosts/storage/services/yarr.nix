{
  config,
  pkgs,
  lib,
  self,
  ...
}: let
  port = 7070;
in {
  sops.secrets."yarr-env" = {};

  media.containers.yarr = {
    image = "ghcr.io/arsfeld/yarr:master";
    listenPort = port;
    exposePort = port;
    configDir = "/data";
    environmentFiles = [
      config.sops.secrets."yarr-env".path
    ];
    settings.funnel = true;
  };

  media.gateway.services.yarr.exposeViaTailscale = true;
}
