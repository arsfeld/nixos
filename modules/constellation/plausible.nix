{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.constellation.plausible;
in {
  options.constellation.plausible = {
    enable = lib.mkEnableOption "self-hosted Plausible Analytics";

    domain = lib.mkOption {
      type = lib.types.str;
      default = "plausible.arsfeld.dev";
      description = "Domain for Plausible Analytics";
    };

    adminUser = lib.mkOption {
      type = lib.types.str;
      default = "admin@arsfeld.dev";
      description = "Admin email for Plausible";
    };

    smtp = {
      host = lib.mkOption {
        type = lib.types.str;
        default = "smtp.gmail.com";
        description = "SMTP server host";
      };

      port = lib.mkOption {
        type = lib.types.int;
        default = 587;
        description = "SMTP server port";
      };

      username = lib.mkOption {
        type = lib.types.str;
        default = "alex@rosenfeld.one";
        description = "SMTP username";
      };

      ssl = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Use SSL for SMTP";
      };

      fromEmail = lib.mkOption {
        type = lib.types.str;
        default = "noreply@arsfeld.dev";
        description = "From email for notifications";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    # Secrets
    age.secrets.plausible-secret-key = {
      file = ../../secrets/plausible-secret-key.age;
      owner = "root";
      group = "root";
    };

    age.secrets.plausible-smtp-password = {
      file = ../../secrets/plausible-smtp-password.age;
      owner = "root";
      group = "root";
    };

    # PostgreSQL for Plausible metadata
    services.postgresql = {
      enable = true;
      ensureDatabases = ["plausible"];
      ensureUsers = [
        {
          name = "plausible";
          ensureDBOwnership = true;
        }
      ];
    };

    # ClickHouse for event data
    services.clickhouse = {
      enable = true;
    };

    # Create environment file for secrets
    systemd.services.plausible-env = {
      description = "Create Plausible environment file";
      before = ["podman-plausible.service"];
      wantedBy = ["podman-plausible.service"];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        mkdir -p /run/plausible
        cat > /run/plausible/env <<EOF
        SECRET_KEY_BASE=$(cat ${config.age.secrets.plausible-secret-key.path})
        SMTP_USER_PWD=$(cat ${config.age.secrets.plausible-smtp-password.path})
        EOF
        chmod 600 /run/plausible/env
      '';
    };

    # Plausible container
    virtualisation.oci-containers.containers.plausible = {
      image = "plausible/analytics:v2.1";
      environment = {
        DISABLE_REGISTRATION = "true";
        BASE_URL = "https://${cfg.domain}";
        DATABASE_URL = "postgres://plausible:plausible@localhost/plausible";
        CLICKHOUSE_DATABASE_URL = "http://localhost:8123/plausible_events_db";
        MAILER_ADAPTER = "Bamboo.SMTPAdapter";
        SMTP_HOST_ADDR = cfg.smtp.host;
        SMTP_HOST_PORT = toString cfg.smtp.port;
        SMTP_USER_NAME = cfg.smtp.username;
        SMTP_HOST_SSL_ENABLED = toString cfg.smtp.ssl;
        MAILER_EMAIL = cfg.smtp.fromEmail;
      };
      environmentFiles = ["/run/plausible/env"];
      ports = ["127.0.0.1:8000:8000"];
      extraOptions = [
        "--network=host"
      ];
      volumes = [
        "/var/lib/plausible:/var/lib/plausible"
      ];
    };

    # Caddy reverse proxy
    services.caddy.virtualHosts.${cfg.domain} = {
      useACMEHost = "arsfeld.dev"; # Use wildcard certificate
      extraConfig = ''
        encode zstd gzip

        header {
          X-Frame-Options "SAMEORIGIN"
          X-Content-Type-Options "nosniff"
          X-XSS-Protection "1; mode=block"
          Referrer-Policy "strict-origin-when-cross-origin"
          Permissions-Policy "geolocation=(), microphone=(), camera=()"
        }

        reverse_proxy localhost:8000 {
          header_up X-Real-IP {remote_host}
          header_up X-Forwarded-For {remote_host}
          header_up X-Forwarded-Proto {scheme}
        }

        @static {
          path /js/* /css/* /images/*
        }

        header @static Cache-Control "public, max-age=31536000, immutable"
      '';
    };

    # Firewall rules
    networking.firewall.allowedTCPPorts = [80 443];

    # Note: Plausible data in /var/lib/plausible will be automatically backed up
    # by the constellation.backup module when enabled, as it backs up all of /var/lib

    # Systemd service ordering
    systemd.services."podman-plausible" = {
      after = ["postgresql.service" "clickhouse.service" "plausible-env.service"];
      requires = ["postgresql.service" "clickhouse.service" "plausible-env.service"];
    };
  };
}
