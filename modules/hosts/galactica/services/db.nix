{
  configurations.nixos.galactica.module = {
    lib,
    pkgs,
    config,
    ...
  }: {
    systemd.services =
      {
        mysql-backup.after = ["mysql.service"];
      }
      // (
        # Upstream postgresqlBackup sets Requires=postgresql.target without After=,
        # racing startup/restarts and causing backup failures. Ensure backups wait for
        # the database service to be ready before dumping.
        lib.genAttrs
        (map (db: "postgresqlBackup-${db}") config.services.postgresqlBackup.databases)
        (_: {
          after = ["postgresql.service"];
        })
      );
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
          name = "openarchiver";
          ensureDBOwnership = true;
        }
        # DISABLED: MediaManager service commented out
        # {
        #   name = "mediamanager";
        #   ensureDBOwnership = true;
        # }
        {
          name = "morphic";
          ensureDBOwnership = true;
        }
      ];
      ensureDatabases = [
        "openarchiver"
        # DISABLED: MediaManager service commented out
        # "mediamanager"
        "morphic"
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
        host openarchiver openarchiver 10.88.0.0/16 trust
        host morphic morphic 10.88.0.0/16 trust
      '';
    };

    services.postgresqlBackup = {
      enable = true;
      startAt = "*-*-* 03:30:00";
      compression = "zstd";
      # bitmagnet is excluded deliberately: it is a DHT crawl index, so losing it
      # costs crawl time rather than irreplaceable data. Dumping it cost 5.3G per
      # night and 10.6G retained (the dump plus its .prev), which was most of
      # /var/backup on a 460G root pool. Everything else here is real state.
      databases = lib.subtractLists ["bitmagnet"] config.services.postgresql.ensureDatabases;
      pgdumpOptions = "--format custom";
    };

    services.mysqlBackup = {
      enable = true;
      databases = config.services.mysql.ensureDatabases;
      calendar = "*-*-* 03:30:00";
      location = "/var/backup/mysql";
    };
  };
}
