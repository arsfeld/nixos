# Constellation OpenCloud module
#
# This module configures OpenCloud, a lightweight self-hosted cloud storage
# platform (FLOSS fork of oCIS). OpenCloud provides file management, sharing,
# and collaboration features without requiring a database.
#
# Key features:
# - Single binary deployment with embedded identity provider
# - OpenID Connect authentication (internal IDP or external like Authelia)
# - WebDAV and web interface access
# - Spaces for organized file management
# - Lightweight resource usage (~100MB RAM)
#
# Integration:
# - Uses media.config for consistent user/group and paths
# - Integrates with constellation.services for gateway routing
# - Supports sops-nix for secret management
#
# Secrets:
# The environmentFile should contain environment variables in the format:
#   IDM_ADMIN_PASSWORD=your-secure-admin-password
#
# To create with sops:
#   1. Add to secrets/sops/storage.yaml:
#      opencloud-env: |
#        IDM_ADMIN_PASSWORD=your-secure-password
#   2. The module will automatically use it when constellation.sops is enabled
{
  config,
  lib,
  self,
  ...
}:
with lib; let
  cfg = config.constellation.opencloud;
  vars = config.media.config;
in {
  options.constellation.opencloud = {
    enable = mkOption {
      type = types.bool;
      description = ''
        Enable OpenCloud file storage and collaboration platform.
        This configures the native NixOS OpenCloud service with
        integration into the constellation infrastructure.
      '';
      default = false;
    };

    port = mkOption {
      type = types.port;
      default = 9200;
      description = "Port for the OpenCloud web interface and API.";
    };

    dataDir = mkOption {
      type = types.str;
      default = "${vars.storageDir}/files/OpenCloud";
      description = "Directory for OpenCloud data storage.";
    };

    url = mkOption {
      type = types.str;
      default = "https://opencloud.${vars.domain}";
      description = "Public URL for OpenCloud.";
    };

    configDir = mkOption {
      type = types.str;
      default = "/var/lib/opencloud";
      description = "Directory for OpenCloud configuration and state.";
    };

    environmentFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = ''
        Path to environment file containing secrets.
        Should contain IDM_ADMIN_PASSWORD=<password> at minimum.
        If null and constellation.sops is enabled, uses sops secret.
      '';
    };
  };

  config = mkIf cfg.enable {
    # Ensure the media user/group exists
    assertions = [
      {
        assertion = config.media.config.enable;
        message = "constellation.opencloud requires media.config.enable = true";
      }
    ];

    # OpenCloud secrets via sops-nix
    # The secret should be in env file format: KEY=value
    sops.secrets.opencloud-env = mkIf (config.constellation.sops.enable && cfg.environmentFile == null) {
      mode = "0400";
      owner = "opencloud";
    };

    # Create data directories with correct permissions
    systemd.tmpfiles.rules = [
      "d ${cfg.dataDir} 0750 opencloud opencloud -"
    ];

    services.opencloud = {
      enable = true;

      # Network configuration
      # Listen on all interfaces to allow cloud gateway to proxy requests
      address = "0.0.0.0";
      port = cfg.port;
      url = cfg.url;

      # Storage configuration
      stateDir = cfg.configDir;

      # Environment file for secrets (admin password, etc.)
      environmentFile =
        if cfg.environmentFile != null
        then cfg.environmentFile
        else if config.constellation.sops.enable
        then config.sops.secrets.opencloud-env.path
        else null;

      # OpenCloud configuration via settings
      # These are written as YAML files in /etc/opencloud/
      settings = {
        # Proxy configuration
        proxy = {
          http.addr = "0.0.0.0:${toString cfg.port}";
          tls = false; # TLS handled by Caddy reverse proxy
        };

        # Storage configuration
        storage-users = {
          mount_id = "storage-users";
          data_path = cfg.dataDir;
        };

        # Web interface settings
        web = {
          ui = {
            # Theme customization
            theme = {
              general = {
                name = "Constellation Cloud";
              };
            };
          };
        };

        # Identity provider settings (using embedded LibreGraph Connect)
        idp = {
          # Embedded IDP is enabled by default
          # For external OIDC (like Authelia), configure oidc settings instead
        };

        # Logging
        log = {
          level = "info";
          pretty = false;
          color = false;
        };
      };

      # Additional environment variables
      environment = {
        # Data path for user files
        OC_BASE_DATA_PATH = cfg.dataDir;
        # Disable TLS (handled by reverse proxy)
        PROXY_TLS = "false";
        # Trust reverse proxy headers
        PROXY_TRUSTED_PROXIES = "127.0.0.1";
      };
    };

    # Ensure opencloud user can access media directories if needed
    users.users.opencloud.extraGroups = ["media"];

    # The upstream module uses ProtectSystem=strict which makes everything read-only
    # except for explicitly allowed paths. We need to add our custom dataDir to the
    # allowed paths so opencloud can write to it.
    systemd.services.opencloud.serviceConfig.ReadWritePaths = [cfg.dataDir];
  };
}
