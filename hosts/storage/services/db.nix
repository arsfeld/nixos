{
  lib,
  pkgs,
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
    ensureDatabases = ["nextcloud" "immich"];
    enableTCPIP = true;
    package = pkgs.postgresql;
    extraPlugins = with pkgs.postgresql.pkgs; [pgvector pgvecto-rs];
    settings = {
      shared_preload_libraries = ["vectors.so"];
    };
    ensureUsers = [
      {
        name = "nextcloud";
        ensureClauses = {
          createrole = true;
          createdb = true;
        };
        ensureDBOwnership = true;
      }
      {
        name = "immich";
        ensureClauses = {
          createrole = true;
          createdb = true;
          superuser = true;
        };
        ensureDBOwnership = true;
      }
    ];
    authentication = lib.mkForce ''
      # Generated file; do not edit!
      # TYPE  DATABASE        USER            ADDRESS                 METHOD
      local   all             all                                     trust
      host    all             all             172.17.0.0/16           trust
      host    all             all             127.0.0.1/32            trust
      host    all             all             ::1/128                 trust
    '';
  };

  services.postgresqlBackup = {
    enable = true;
    compression = "zstd";
  };
}
