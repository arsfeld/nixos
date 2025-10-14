{
  self,
  lib,
  config,
  pkgs,
  inputs,
  ...
}: let
  vars = config.media.config;
  # Use unstable for Immich 2.0
  pkgs-unstable = import inputs.nixpkgs-unstable {
    inherit (pkgs) system;
    config.allowUnfree = true;
  };
in {
  services.immich = {
    enable = true;
    package = pkgs-unstable.immich; # Use Immich 2.0.1 from unstable
    mediaLocation = "${vars.dataDir}/files/Immich";
    host = "0.0.0.0";
    port = 15777;
    database = {
      enableVectorChord = true;
      enableVectors = false; # Use VectorChord instead of old pgvecto-rs
    };
    settings = {
      server.externalDomain = "https://immich.${vars.domain}";
      storageTemplate.enabled = true;
    };
  };

  systemd.services.immich-server = {
    after = ["mnt-storage.mount"];
    requires = ["mnt-storage.mount"];
  };
}
