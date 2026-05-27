{
  self,
  config,
  lib,
  ...
}: let
  mkService = import "${self}/modules/media/__mkService.nix" {inherit lib;};
in
  lib.mkMerge [
    {sops.secrets."finance-tracker-env" = {};}

    (mkService "home" {
      port = 8085;
      tailscaleExposed = true;
    })

    (mkService "www" {
      port = 8085;
      tailscaleExposed = true;
    })

    (mkService "finance-tracker" {
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
    })
  ]
