{
  self,
  config,
  lib,
  ...
}: let
  mkService = import "${self}/modules/media/__mkService.nix" {inherit lib;};
in
  lib.mkMerge [
    {
      media.gateway.services.home = {
        port = 8085;
        exposeViaTailscale = true;
        settings.funnel = true;
      };
      media.gateway.services.www = {
        port = 8085;
        exposeViaTailscale = true;
      };

      age.secrets."finance-tracker-env" = {
        file = "${self}/secrets/finance-tracker-env.age";
      };
    }

    (mkService "finance-tracker" {
      port = 8080;
      image = "ghcr.io/arsfeld/finance-tracker:latest";
      container = {
        environmentFiles = [
          config.age.secrets."finance-tracker-env".path
        ];
        environment = {
          SYNC_SCHEDULE = "0 0 17 */2 * *";
        };
      };
    })
  ]
