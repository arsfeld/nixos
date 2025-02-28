{
  self,
  lib,
  config,
  pkgs,
  ...
}: let
  vars = config.mediaConfig;
in {
  services.immich = {
    enable = true;
    mediaLocation = "${vars.dataDir}/files/Immich";
    host = "0.0.0.0";
    port = 15777;
    settings = {
      server.externalDomain = "https://immich.${vars.domain}";
      storageTemplate.enabled = true;
    };
  };
}
