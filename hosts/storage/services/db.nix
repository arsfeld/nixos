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
    # Allow media user to connect as immich database user for file permissions
    identMap = ''
      immich-users media immich
    '';
    authentication = lib.mkAfter ''
      local immich immich peer map=immich-users
    '';
  };

  services.postgresqlBackup = {
    enable = true;
    compression = "zstd";
    databases = config.services.postgresql.ensureDatabases;
    pgdumpOptions = "--format custom";
  };
}
