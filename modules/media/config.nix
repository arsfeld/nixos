# Media configuration module
#
# This module provides centralized configuration for media services including
# directory paths, user management, and SSL certificate settings.
#
# Key features:
# - Unified user/group management for media services
# - Standardized directory structure for config and data
# - ACME/Let's Encrypt integration with Cloudflare DNS
# - Consistent timezone and email settings
# - Domain configuration for public and Tailscale access
#
# This module ensures all media services run under the same user account
# with proper permissions and consistent configuration paths.
{
  config,
  pkgs,
  lib,
  self,
  ...
}: let
  cfg = config.media.config;
in {
  options.media.config = with lib; {
    enable = mkEnableOption "media service configuration";

    configDir = mkOption {
      type = types.str;
      default = "/var/data";
      description = ''
        Base directory for media service configuration files.
        Each service will create its own subdirectory here.
      '';
    };

    dataDir = mkOption {
      type = types.str;
      default = "/mnt/storage";
      description = ''
        Primary data directory for media files.
        This should point to your main storage location.
      '';
    };

    storageDir = mkOption {
      type = types.str;
      default = "/mnt/storage";
      description = ''
        Storage directory for large media files and backups.
        Often the same as dataDir but can be configured separately.
      '';
    };

    puid = mkOption {
      type = types.int;
      default = 5000;
      description = ''
        User ID for the media service user.
        All media services will run under this UID.
      '';
    };

    pgid = mkOption {
      type = types.int;
      default = 5000;
      description = ''
        Group ID for the media service group.
        All media services will run under this GID.
      '';
    };

    user = mkOption {
      type = types.str;
      default = "media";
      description = ''
        Username for the media service account.
        This user will own all media files and run all services.
      '';
    };

    group = mkOption {
      type = types.str;
      default = "media";
      description = ''
        Group name for the media service account.
      '';
    };

    tz = mkOption {
      type = types.str;
      default = "America/Toronto";
      description = ''
        Timezone for media services.
        Used for scheduling and timestamp display.
      '';
    };

    email = mkOption {
      type = types.str;
      default = "arsfeld@gmail.com";
      description = ''
        Email address for ACME certificate notifications
        and service administrative contacts.
      '';
    };

    domain = mkOption {
      type = types.str;
      default = "arsfeld.one";
      description = ''
        Primary domain for public-facing media services.
        SSL certificates will be issued for this domain and its subdomains.
      '';
    };

    tsDomain = mkOption {
      type = types.str;
      default = "bat-boa.ts.net";
      description = ''
        Tailscale domain for internal access to media services.
        Services will be accessible at <service>.<tsDomain>.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    users.users.${cfg.user} = {
      name = cfg.user;
      group = cfg.group;
      uid = cfg.puid;
      isSystemUser = true;
      extraGroups = ["video" "render"]; # For hardware video encoding (VAAPI)
    };

    users.groups.${cfg.group} = {
      name = cfg.group;
      gid = cfg.pgid;
    };

    age.secrets.cloudflare = {
      file = "${self}/secrets/cloudflare.age";
      owner = "acme";
      group = "acme";
    };

    security.acme.acceptTerms = true;

    security.acme.defaults = {
      email = cfg.email;
      dnsResolver = "1.1.1.1:53";
      dnsProvider = "cloudflare";
      credentialsFile = config.age.secrets.cloudflare.path;
    };
  };
}
