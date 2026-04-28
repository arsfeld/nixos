{
  lib,
  config,
  pkgs,
  inputs,
  ...
}: let
  vars = config.media.config;
  # Use unstable for Immich 2.0
  pkgs-unstable = import inputs.nixpkgs-unstable {
    system = pkgs.stdenv.hostPlatform.system;
    config.allowUnfree = true;
  };
in {
  media.gateway.services.immich = {
    port = 15777;
    exposeViaTailscale = true;
    settings = {
      bypassAuth = true;
    };
  };

  sops.secrets.immich-oidc-secret = {
    mode = "0400";
    owner = vars.user;
  };

  services.immich = {
    enable = true;
    package = pkgs-unstable.immich; # Use Immich 2.0.1 from unstable
    mediaLocation = "${vars.dataDir}/files/Immich";
    host = "0.0.0.0";
    port = 15777;
    # Use the media user/group to avoid unsafe path transition warnings
    # since /mnt/storage/files is owned by media:media
    user = vars.user;
    group = vars.group;
    database = {
      enableVectorChord = true;
      enableVectors = false; # Use VectorChord instead of old pgvecto-rs
      user = "immich"; # Keep using immich database role while service runs as media user
    };
    # Override DB_URL to include the immich username for proper PostgreSQL authentication
    # Use localhost as dummy host so Node.js URL parser succeeds; Unix socket still used via host param
    environment.DB_URL = lib.mkForce "postgresql://immich@localhost/immich?host=/run/postgresql";
    settings = {
      server.externalDomain = "https://immich.${vars.domain}";
      storageTemplate.enabled = true;
      oauth = {
        enabled = true;
        issuerUrl = "https://auth.${vars.domain}";
        clientId = "immich";
        clientSecret._secret = config.sops.secrets.immich-oidc-secret.path;
        scope = "openid email profile";
        signingAlgorithm = "RS256";
        autoRegister = true;
        autoLaunch = false;
        buttonText = "Login with Authelia";
        storageLabelClaim = "preferred_username";
      };
    };
  };

  systemd.services.immich-server = {
    after = ["mnt-storage.mount"];
    requires = ["mnt-storage.mount"];
  };
}
