{
  lib,
  pkgs,
  config,
  ...
}: {
  # Redis instance for Seafile caching
  services.redis.servers.seafile = {
    enable = true;
    port = 6379;
    # `-10.88.0.1` (leading dash) marks the Podman bridge address as optional.
    # The bridge is created lazily by Podman, so it may not exist when Redis
    # starts at boot — without this, the unit fails until first manual restart.
    bind = "127.0.0.1 -10.88.0.1";
    settings.protected-mode = "no";
  };

  # MariaDB database setup for Seafile (TCP password auth for container access)
  sops.secrets.seafile-mysql-password = {};

  systemd.services.seafile-db-setup = {
    description = "Create Seafile MariaDB databases and user";
    after = ["mysql.service"];
    requires = ["mysql.service"];
    before = ["podman-seafile.service"];
    requiredBy = ["podman-seafile.service"];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      PASS=$(cat ${config.sops.secrets.seafile-mysql-password.path})
      ${pkgs.mariadb}/bin/mysql -u root <<SQL
        CREATE DATABASE IF NOT EXISTS ccnet_db CHARACTER SET utf8mb4;
        CREATE DATABASE IF NOT EXISTS seafile_db CHARACTER SET utf8mb4;
        CREATE DATABASE IF NOT EXISTS seahub_db CHARACTER SET utf8mb4;
        CREATE USER IF NOT EXISTS 'seafile'@'%' IDENTIFIED BY '$PASS';
        ALTER USER 'seafile'@'%' IDENTIFIED BY '$PASS';
        GRANT ALL PRIVILEGES ON \`ccnet_db\`.* TO 'seafile'@'%';
        GRANT ALL PRIVILEGES ON \`seafile_db\`.* TO 'seafile'@'%';
        GRANT ALL PRIVILEGES ON \`seahub_db\`.* TO 'seafile'@'%';
        -- Grant root TCP access from Podman network (needed for Seafile container init)
        CREATE USER IF NOT EXISTS 'root'@'10.88.0.%' IDENTIFIED BY '$PASS';
        GRANT ALL PRIVILEGES ON *.* TO 'root'@'10.88.0.%' WITH GRANT OPTION;
        FLUSH PRIVILEGES;
      SQL
    '';
  };
  services.mysql = {
    enable = true;
    package = pkgs.mariadb;
    settings.mysqld.skip-name-resolve = true;
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
        name = "bitmagnet";
        ensureDBOwnership = true;
      }
      {
        name = "openarchiver";
        ensureDBOwnership = true;
      }
      # DISABLED: MediaManager service commented out
      # {
      #   name = "mediamanager";
      #   ensureDBOwnership = true;
      # }
    ];
    ensureDatabases = [
      "bitmagnet"
      "openarchiver"
      # DISABLED: MediaManager service commented out
      # "mediamanager"
    ];
    # Allow media user to connect as immich database user for file permissions
    identMap = ''
      immich-users media immich
      openarchiver-users media openarchiver
    '';
    authentication = lib.mkAfter ''
      local immich immich peer map=immich-users
      local openarchiver openarchiver peer map=openarchiver-users
      # Allow containers to connect from podman network without password (trust)
      host bitmagnet bitmagnet 10.88.0.0/16 trust
      host openarchiver openarchiver 10.88.0.0/16 trust
    '';
  };

  services.postgresqlBackup = {
    enable = true;
    compression = "zstd";
    databases = config.services.postgresql.ensureDatabases;
    pgdumpOptions = "--format custom";
  };

  services.mysqlBackup = {
    enable = true;
    databases = config.services.mysql.ensureDatabases ++ ["ccnet_db" "seafile_db" "seahub_db"];
    calendar = "daily";
    location = "/var/backup/mysql";
  };
}
