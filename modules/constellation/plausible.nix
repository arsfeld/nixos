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
      owner = "plausible";
      group = "plausible";
    };

    age.secrets.plausible-smtp-password = {
      file = ../../secrets/plausible-smtp-password.age;
      owner = "plausible";
      group = "plausible";
    };

    # Use the native NixOS Plausible service
    services.plausible = {
      enable = true;

      server = {
        baseUrl = "https://${cfg.domain}";
        disableRegistration = false; # Temporarily enable to create admin user
        port = 8100; # Avoid conflict with Vaultwarden on 8000
        secretKeybaseFile = config.age.secrets.plausible-secret-key.path;
      };

      mail = {
        email = cfg.smtp.fromEmail;
        smtp = {
          hostAddr = cfg.smtp.host;
          hostPort = cfg.smtp.port;
          enableSSL = cfg.smtp.ssl;
          user = cfg.smtp.username;
          passwordFile = config.age.secrets.plausible-smtp-password.path;
        };
      };
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

        reverse_proxy localhost:8100 {
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
  };
}
