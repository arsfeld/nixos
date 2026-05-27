{
  self,
  config,
  lib,
  ...
}: let
  mkService = import "${self}/modules/media/__mkService.nix" {inherit lib;};
in
  lib.mkMerge [
    {sops.secrets."yarr-env" = {};}

    (mkService "yarr" {
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
    })
  ]
