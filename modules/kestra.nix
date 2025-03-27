{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.kestra;
  types = lib.types;
  mkOption = lib.mkOption;
in {
  options.services.kestra = {
    enable = lib.mkEnableOption "Kestra workflow orchestration";

    database = {
      createLocally = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Create the database and database user locally.
        '';
      };

      host = mkOption {
        type = types.str;
        default = "localhost";
        description = ''
          Hostname hosting the database.
        '';
      };

      name = mkOption {
        type = types.str;
        default = "kestra";
        description = ''
          Name of database.
        '';
      };

      username = mkOption {
        type = types.str;
        default = "kestra";
        description = ''
          Username for accessing the database.
        '';
      };

      password = mkOption {
        type = types.str;
        default = "kestra";
        description = ''
          Password for the database user
        '';
      };
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 8080;
      description = "Port for the Kestra UI";
    };

    adminPort = lib.mkOption {
      type = lib.types.port;
      default = 8081;
      description = "Port for the Kestra administration interface";
    };

    basicAuth = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable basic authentication";
    };

    basicAuthUsername = lib.mkOption {
      type = lib.types.str;
      default = "admin@localhost.dev";
      description = "Basic auth username (must be a valid email address)";
    };

    basicAuthPassword = lib.mkOption {
      type = lib.types.str;
      default = "kestra";
      description = "Basic auth password";
    };
  };

  config = lib.mkIf cfg.enable {
    # PostgreSQL Configuration - only if createLocally is true
    services.postgresql = lib.mkIf cfg.database.createLocally {
      enable = true;
      ensureDatabases = [cfg.database.name];
      ensureUsers = [
        {
          name = cfg.database.username;
          ensureDBOwnership = true;
        }
      ];
    };

    # Set PostgreSQL password if creating locally
    systemd.services.postgresql.postStart = lib.mkIf cfg.database.createLocally (lib.mkAfter ''
      $PSQL -c "ALTER USER ${cfg.database.username} WITH PASSWORD '${cfg.database.password}';"
    '');

    # OCI Container Configuration for Kestra
    virtualisation.oci-containers = {
      backend = "podman";
      containers = {
        kestra = {
          image = "kestra/kestra:latest";
          cmd = ["server" "standalone"];
          user = "root"; # Note: as per comment in docker-compose, this is intended for development
          ports = [
            "${toString cfg.port}:8080"
            "${toString cfg.adminPort}:8081"
          ];
          volumes = [
            "/var/lib/kestra:/app/storage"
            "/var/run/docker.sock:/var/run/docker.sock"
            "/tmp/kestra-wd:/tmp/kestra-wd"
          ];
          environment = {
            KESTRA_CONFIGURATION = ''
              datasources:
                postgres:
                  url: jdbc:postgresql://${cfg.database.host}:5432/${cfg.database.name}
                  driverClassName: org.postgresql.Driver
                  username: ${cfg.database.username}
                  password: ${cfg.database.password}
              kestra:
                server:
                  basicAuth:
                    enabled: ${lib.boolToString cfg.basicAuth}
                    username: "${cfg.basicAuthUsername}"
                    password: ${cfg.basicAuthPassword}
                repository:
                  type: postgres
                storage:
                  type: local
                  local:
                    basePath: "/app/storage"
                queue:
                  type: postgres
                tasks:
                  tmpDir:
                    path: /tmp/kestra-wd/tmp
                url: http://localhost:${toString cfg.port}/
            '';
          };
          # Only use host networking if database is local
          extraOptions = lib.mkIf (cfg.database.host == "localhost" || cfg.database.host == "127.0.0.1") [
            "--network=host"
          ];
        };
      };
    };

    # Create volumes for Kestra
    systemd.tmpfiles.rules = [
      "d /var/lib/kestra 0700 root root - -"
      "d /tmp/kestra-wd 0755 root root - -"
      "d /tmp/kestra-wd/tmp 0755 root root - -"
    ];
  };
}
