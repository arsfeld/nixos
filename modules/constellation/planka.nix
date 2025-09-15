{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.constellation.planka;
in {
  options.constellation.planka = {
    enable = lib.mkEnableOption "Planka kanban board";

    domain = lib.mkOption {
      type = lib.types.str;
      default = "planka.arsfeld.dev";
      description = "Domain for Planka";
    };

    dataDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/planka";
      description = "Data directory for Planka";
    };

    database = {
      host = lib.mkOption {
        type = lib.types.str;
        default = "localhost";
        description = "PostgreSQL host";
      };

      port = lib.mkOption {
        type = lib.types.int;
        default = 5432;
        description = "PostgreSQL port";
      };

      name = lib.mkOption {
        type = lib.types.str;
        default = "planka";
        description = "PostgreSQL database name";
      };

      user = lib.mkOption {
        type = lib.types.str;
        default = "planka";
        description = "PostgreSQL user";
      };
    };

    port = lib.mkOption {
      type = lib.types.int;
      default = 1337;
      description = "Port for Planka to listen on";
    };
  };

  config = lib.mkIf cfg.enable {
    # Create necessary directories
    systemd.tmpfiles.rules = [
      "d ${cfg.dataDir} 0755 root root -"
      "d ${cfg.dataDir}/user-avatars 0755 root root -"
      "d ${cfg.dataDir}/project-background-images 0755 root root -"
      "d ${cfg.dataDir}/attachments 0755 root root -"
      "d /run/planka 0700 root root -"
    ];

    # PostgreSQL database
    services.postgresql = {
      enable = true;
      ensureDatabases = [cfg.database.name];
      ensureUsers = [
        {
          name = cfg.database.user;
          ensureDBOwnership = true;
        }
      ];
    };

    # Set PostgreSQL password after database is created
    systemd.services.postgresql.postStart = lib.mkAfter ''
      $PSQL -tA <<EOF
        ALTER USER ${cfg.database.user} WITH PASSWORD '$(cat ${config.age.secrets.planka-db-password.path})';
      EOF
    '';

    # Planka container
    virtualisation.oci-containers.containers.planka = {
      image = "ghcr.io/plankanban/planka:latest";
      environment = {
        BASE_URL = "https://${cfg.domain}";
        DEFAULT_ADMIN_EMAIL = "admin@example.com";
        DEFAULT_ADMIN_NAME = "Admin";
        DEFAULT_ADMIN_USERNAME = "admin";
        DEFAULT_ADMIN_PASSWORD = "changeme";
        TRUST_PROXY = "1";
      };
      environmentFiles = [
        "/run/planka/env"
      ];
      volumes = [
        "${cfg.dataDir}/user-avatars:/app/public/user-avatars"
        "${cfg.dataDir}/project-background-images:/app/public/project-background-images"
        "${cfg.dataDir}/attachments:/app/private/attachments"
      ];
      ports = [
        "${toString cfg.port}:1337"
      ];
      extraOptions = [
        "--network=host" # Use host network for database access
      ];
    };

    # Create environment file for Planka container
    systemd.services.docker-planka = {
      preStart = lib.mkAfter ''
        PASSWORD=$(cat ${config.age.secrets.planka-db-password.path})
        ENCODED_PASSWORD=$(${pkgs.python3}/bin/python3 -c "import sys, urllib.parse; print(urllib.parse.quote(sys.stdin.read().strip()))" <<< "$PASSWORD")
        cat > /run/planka/env <<EOF
        DATABASE_URL=postgresql://${cfg.database.user}:$ENCODED_PASSWORD@${cfg.database.host}:${toString cfg.database.port}/${cfg.database.name}
        SECRET_KEY=$(cat ${config.age.secrets.planka-secret-key.path})
        EOF
      '';
    };

    # Caddy reverse proxy
    services.caddy.virtualHosts.${cfg.domain} = {
      useACMEHost = "arsfeld.dev";
      extraConfig = ''
        encode zstd gzip

        header {
          X-Frame-Options "SAMEORIGIN"
          X-Content-Type-Options "nosniff"
          X-XSS-Protection "1; mode=block"
          Referrer-Policy "strict-origin-when-cross-origin"
        }

        reverse_proxy localhost:${toString cfg.port} {
          header_up X-Real-IP {remote_host}
          header_up X-Forwarded-For {remote_host}
          header_up X-Forwarded-Proto {scheme}
        }
      '';
    };

    # Secrets
    age.secrets = {
      planka-db-password = {
        file = ../../secrets/planka-db-password.age;
        owner = "root";
        group = "root";
      };
      planka-secret-key = {
        file = ../../secrets/planka-secret-key.age;
        owner = "root";
        group = "root";
      };
    };
  };
}
