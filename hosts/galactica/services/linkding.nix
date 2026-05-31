{
  self,
  config,
  lib,
  ...
}: let
  mkService = import "${self}/modules/media/__mkService.nix" {inherit lib;};
in
  lib.mkMerge [
    {sops.secrets."linkding-env" = {};}

    (mkService "linkding" {
      port = 9090;
      image = "ghcr.io/sissbruecker/linkding:latest";
      bypassAuth = true; # linkding has its own auth; browser extension/REST API need direct access
      tailscaleExposed = true;
      container = {
        exposePort = 9090;
        configDir = "/etc/linkding/data";
        environmentFiles = [
          config.sops.secrets."linkding-env".path
        ];
      };
    })
  ]
