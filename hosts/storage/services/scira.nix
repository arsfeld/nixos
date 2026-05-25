{
  self,
  config,
  lib,
  ...
}: let
  mkService = import "${self}/modules/media/__mkService.nix" {inherit lib;};
in
  lib.mkMerge [
    {sops.secrets."scira-env" = {};}

    (mkService "scira" {
      port = 3000;
      # Built and pushed by .github/workflows/scira-image.yml from
      # zaidmukaddam/scira — no prebuilt image exists upstream.
      image = "ghcr.io/arsfeld/scira:latest";
      tailscaleExposed = true;
      watchImage = true;
      container = {
        environmentFiles = [
          config.sops.secrets."scira-env".path
        ];
        environment = {
          NODE_ENV = "production";
          PORT = "3000";
          HOSTNAME = "0.0.0.0";
        };
      };
    })
  ]
