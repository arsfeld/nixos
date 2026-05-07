{
  self,
  config,
  lib,
  ...
}: let
  mkService = import "${self}/modules/media/__mkService.nix" {inherit lib;};
  vars = config.media.config;
  url = "https://cinephage.${vars.domain}";
in
  lib.mkMerge [
    {sops.secrets."cinephage-env" = {};}

    (mkService "cinephage" {
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
    })
  ]
