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

  # OAuth config template - secret will be injected at runtime
  oauthConfigTemplate = pkgs.writeText "immich-oauth-config.json" (builtins.toJSON {
    oauth = {
      enabled = true;
      issuerUrl = "https://auth.${vars.domain}";
      clientId = "immich";
      clientSecret = "@IMMICH_OAUTH_CLIENT_SECRET@";
      scope = "openid email profile";
      signingAlgorithm = "RS256";
      autoRegister = true;
      autoLaunch = false;
      buttonText = "Login with Authelia";
      storageLabelClaim = "preferred_username";
    };
  });
in {
  age.secrets.immich-oidc-secret = {
    file = "${self}/secrets/immich-oidc-secret.age";
    mode = "400";
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
    environment.DB_URL = lib.mkForce "postgresql://immich@/immich?host=/run/postgresql";
    # Override config file to inject OAuth secret at runtime
    environment.IMMICH_CONFIG_FILE = lib.mkForce "/run/immich/config.json";
    settings = {
      server.externalDomain = "https://immich.${vars.domain}";
      storageTemplate.enabled = true;
    };
  };

  systemd.services.immich-server = {
    after = ["mnt-storage.mount"];
    requires = ["mnt-storage.mount"];
    preStart = ''
      # Inject OAuth client secret into config file
      ${pkgs.gnused}/bin/sed \
        "s|@IMMICH_OAUTH_CLIENT_SECRET@|$(cat ${config.age.secrets.immich-oidc-secret.path})|g" \
        ${oauthConfigTemplate} > /run/immich/config.json
      chown ${vars.user}:${vars.group} /run/immich/config.json
      chmod 600 /run/immich/config.json
    '';
  };
}
