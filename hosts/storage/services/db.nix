{
  lib,
  pkgs,
  config,
  ...
}: {
  services.mysql = {
    enable = true;
    package = pkgs.mariadb;
    ensureUsers = [
      {
        name = "filerun";
        ensurePermissions = {
          "filerun.*" = "ALL PRIVILEGES";
        };
      }
      {
        name = "romm";
        ensurePermissions = {
          "romm.*" = "ALL PRIVILEGES";
        };
      }
    ];
    ensureDatabases = [
      "filerun"
      "romm"
    ];
  };

  services.postgresql = {
    enable = true;
    package = pkgs.postgresql_16_jit;
    # Listen on all interfaces to allow container connections
    enableTCPIP = true;
    settings = {
      listen_addresses = "*";
    };
    ensureUsers = [
      {
        name = "openarchiver";
        ensureDBOwnership = true;
      }
      {
        name = "mediamanager";
        ensureDBOwnership = true;
      }
    ];
    ensureDatabases = [
      "openarchiver"
      "mediamanager"
    ];
    # Allow media user to connect as immich database user for file permissions
    identMap = ''
      immich-users media immich
      openarchiver-users media openarchiver
      mediamanager-users media mediamanager
    '';
    authentication = lib.mkAfter ''
      local immich immich peer map=immich-users
      local openarchiver openarchiver peer map=openarchiver-users
      local mediamanager mediamanager peer map=mediamanager-users
      # Allow OpenArchiver container to connect from podman network without password (trust)
      host openarchiver openarchiver 10.88.0.0/16 trust
      # Allow MediaManager container to connect from podman network without password (trust)
      host mediamanager mediamanager 10.88.0.0/16 trust
    '';
  };

  services.postgresqlBackup = {
    enable = true;
    compression = "zstd";
    databases = config.services.postgresql.ensureDatabases;
    pgdumpOptions = "--format custom";
  };
}
