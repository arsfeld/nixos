# Plane project management service
#
# This module deploys Plane (https://github.com/makeplane/plane) as a set of
# containerized services on NixOS. Plane is an open-source alternative to Jira,
# Linear, Monday, and ClickUp.
#
# Architecture:
# - PostgreSQL database (host-level, shared with other services)
# - Infrastructure containers: Redis, RabbitMQ, MinIO
# - Application containers: API, worker, beat, migrator, web, space, admin, live
# - Caddy reverse proxy for SSL termination and routing
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.plane;

  # Version of Plane to deploy
  planeVersion = "stable";

  # Common environment variables for backend containers
  # Note: Backend containers use --network=host, so they need localhost addresses
  planeEnv = {
    DEBUG = "0";
    SENTRY_DSN = "";
    WEB_URL = "https://${cfg.domain}";
    CORS_ALLOWED_ORIGINS = "https://${cfg.domain}";
    GUNICORN_WORKERS = "1";
    PORT = "8006"; # Use non-default port since 8000 is taken by Vaultwarden

    # Redis (localhost since backend uses host network)
    REDIS_URL = "redis://localhost:6379/";

    # RabbitMQ (localhost since backend uses host network)
    RABBITMQ_HOST = "localhost";
    RABBITMQ_PORT = "5672";
    RABBITMQ_USER = "plane";
    RABBITMQ_PASSWORD = "plane";
    RABBITMQ_VHOST = "plane";

    # MinIO/S3 (localhost since backend uses host network)
    USE_MINIO = "1";
    AWS_S3_ENDPOINT_URL = "http://localhost:9010";
    AWS_ACCESS_KEY_ID = "plane";
    AWS_SECRET_ACCESS_KEY = "planeminio";
    AWS_S3_BUCKET_NAME = "uploads";
    AWS_REGION = "us-east-1";

    # File uploads
    FILE_SIZE_LIMIT = "5242880";
  };
in {
  options.services.plane = {
    enable = lib.mkEnableOption "Plane project management";

    domain = lib.mkOption {
      type = lib.types.str;
      default = "plane.arsfeld.dev";
      description = "Domain for Plane";
    };

    dataDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/plane";
      description = "Data directory for Plane";
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
        default = "plane";
        description = "PostgreSQL database name";
      };

      user = lib.mkOption {
        type = lib.types.str;
        default = "plane";
        description = "PostgreSQL user";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    # Create necessary directories
    systemd.tmpfiles.rules = [
      "d ${cfg.dataDir} 0755 root root -"
      "d ${cfg.dataDir}/redis 0755 root root -"
      "d ${cfg.dataDir}/rabbitmq 0755 root root -"
      "d ${cfg.dataDir}/minio 0755 root root -"
      "d /run/plane 0700 root root -"
    ];

    # PostgreSQL database
    services.postgresql = {
      enable = true;
      enableTCPIP = true;
      ensureDatabases = [cfg.database.name];
      ensureUsers = [
        {
          name = cfg.database.user;
          ensureDBOwnership = true;
        }
      ];
      authentication = lib.mkAfter ''
        host ${cfg.database.name} ${cfg.database.user} 127.0.0.1/32 scram-sha-256
        host ${cfg.database.name} ${cfg.database.user} ::1/128 scram-sha-256
      '';
    };

    # Set PostgreSQL password after database is created
    systemd.services.postgresql.postStart = lib.mkAfter ''
      psql -U postgres -tA <<EOF
        ALTER USER ${cfg.database.user} WITH PASSWORD '$(cat ${config.sops.secrets.plane-db-password.path})';
      EOF
    '';

    # Infrastructure and application containers
    virtualisation.oci-containers.containers = {
      # Redis for caching and sessions
      plane-redis = {
        image = "valkey/valkey:7.2-alpine";
        volumes = ["${cfg.dataDir}/redis:/data"];
        ports = ["127.0.0.1:6379:6379"];
      };

      # RabbitMQ for message queue
      plane-mq = {
        image = "rabbitmq:3.13-management-alpine";
        environment = {
          RABBITMQ_DEFAULT_USER = "plane";
          RABBITMQ_DEFAULT_PASS = "plane";
          RABBITMQ_DEFAULT_VHOST = "plane";
        };
        volumes = ["${cfg.dataDir}/rabbitmq:/var/lib/rabbitmq"];
        ports = ["127.0.0.1:5672:5672"];
      };

      # MinIO for S3-compatible storage
      plane-minio = {
        image = "minio/minio";
        cmd = ["server" "/data" "--address" ":9010" "--console-address" ":9011"];
        environment = {
          MINIO_ROOT_USER = "plane";
          MINIO_ROOT_PASSWORD = "planeminio";
        };
        volumes = ["${cfg.dataDir}/minio:/data"];
        ports = ["127.0.0.1:9010:9010"];
      };

      # Database migrator (runs first, then exits)
      plane-migrator = {
        image = "makeplane/plane-backend:${planeVersion}";
        dependsOn = ["plane-redis" "plane-mq"];
        environment = planeEnv;
        environmentFiles = ["/run/plane/env"];
        extraOptions = ["--network=host"];
        cmd = ["./bin/docker-entrypoint-migrator.sh"];
      };

      # API server
      # Note: Don't depend on plane-migrator because it exits after completing,
      # which would cause systemd to stop the API. Use after-override instead.
      plane-api = {
        image = "makeplane/plane-backend:${planeVersion}";
        dependsOn = ["plane-redis" "plane-mq" "plane-minio"];
        environment = planeEnv;
        environmentFiles = ["/run/plane/env"];
        extraOptions = ["--network=host"];
        cmd = ["./bin/docker-entrypoint-api.sh"];
      };

      # Background worker
      plane-worker = {
        image = "makeplane/plane-backend:${planeVersion}";
        dependsOn = ["plane-api"];
        environment = planeEnv;
        environmentFiles = ["/run/plane/env"];
        extraOptions = ["--network=host"];
        cmd = ["./bin/docker-entrypoint-worker.sh"];
      };

      # Beat scheduler
      plane-beat = {
        image = "makeplane/plane-backend:${planeVersion}";
        dependsOn = ["plane-api"];
        environment = planeEnv;
        environmentFiles = ["/run/plane/env"];
        extraOptions = ["--network=host"];
        cmd = ["./bin/docker-entrypoint-beat.sh"];
      };

      # Web frontend
      plane-web = {
        image = "makeplane/plane-frontend:${planeVersion}";
        dependsOn = ["plane-api"];
        environment = {
          NEXT_PUBLIC_API_BASE_URL = "https://${cfg.domain}";
          NEXT_PUBLIC_DEPLOY_URL = "https://${cfg.domain}/spaces";
        };
        ports = ["3000:3000"];
      };

      # Public spaces
      plane-space = {
        image = "makeplane/plane-space:${planeVersion}";
        dependsOn = ["plane-api"];
        environment = {
          NEXT_PUBLIC_API_BASE_URL = "https://${cfg.domain}";
        };
        ports = ["3001:3000"];
      };

      # Admin panel (God Mode)
      plane-admin = {
        image = "makeplane/plane-admin:${planeVersion}";
        dependsOn = ["plane-api"];
        environment = {
          NEXT_PUBLIC_API_BASE_URL = "https://${cfg.domain}";
        };
        ports = ["3002:3000"];
      };

      # Real-time collaboration
      plane-live = {
        image = "makeplane/plane-live:${planeVersion}";
        dependsOn = ["plane-api" "plane-redis"];
        environment = planeEnv;
        environmentFiles = ["/run/plane/env"];
        ports = ["3003:3000"];
      };
    };

    # Create environment file for containers with secrets
    # Also configure to start after migrator (but not require it, since migrator exits)
    systemd.services.docker-plane-api = {
      requires = ["postgresql.service"];
      after = ["postgresql.service" "docker-plane-migrator.service"];
      preStart = lib.mkAfter ''
        PASSWORD=$(cat ${config.sops.secrets.plane-db-password.path})
        # URL-encode the password to handle special characters like / and =
        # Use safe="" to ensure all special characters including / are encoded
        ENCODED_PASSWORD=$(${pkgs.python3}/bin/python3 -c "import sys, urllib.parse; print(urllib.parse.quote(sys.stdin.read().strip(), safe=\"\"))" <<< "$PASSWORD")
        SECRET_KEY=$(cat ${config.sops.secrets.plane-secret-key.path})
        cat > /run/plane/env <<EOF
        DATABASE_URL=postgresql://${cfg.database.user}:$ENCODED_PASSWORD@${cfg.database.host}:${toString cfg.database.port}/${cfg.database.name}
        SECRET_KEY=$SECRET_KEY
        EOF
        chmod 600 /run/plane/env
      '';
    };

    # Migrator should be a oneshot service (doesn't restart when it completes)
    systemd.services.docker-plane-migrator = {
      serviceConfig.Restart = lib.mkForce "no";
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

        # API routes (Django backend)
        @api path /api/* /auth/*
        handle @api {
          reverse_proxy localhost:8006 {
            header_up X-Real-IP {remote_host}
            header_up X-Forwarded-For {remote_host}
            header_up X-Forwarded-Proto {scheme}
          }
        }

        # Live/WebSocket for real-time collaboration
        @live path /live/*
        handle @live {
          reverse_proxy localhost:3003
        }

        # Admin panel (God Mode)
        @admin path /god-mode/*
        handle @admin {
          reverse_proxy localhost:3002
        }

        # Public spaces
        @space path /spaces/*
        handle @space {
          reverse_proxy localhost:3001
        }

        # Default to web frontend
        handle {
          reverse_proxy localhost:3000
        }
      '';
    };
  };
}
