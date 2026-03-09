{
  self,
  lib,
  ...
}: let
  mkService = import "${self}/modules/media/__mkService.nix" {inherit lib;};
in
  mkService "metube" {
    port = 8081;
    image = "ghcr.io/alexta69/metube";
    container = {
      configDir = null;
      volumes = ["/var/lib/metube:/downloads"];
    };
  }
