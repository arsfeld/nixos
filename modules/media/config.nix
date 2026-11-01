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
{self, ...}: {
  flake.modules.nixos.media = {
    key = "modules/media/config";
    imports = [
      ({
        config,
        pkgs,
        lib,
        ...
      }: let
        cfg = config.media.config;
      in {
        options.media.config = {
          enable = lib.mkEnableOption "media service configuration";

          configDir = lib.mkOption {
            type = lib.types.str;
            default = "/var/data";
            description = ''
              Base directory for media service configuration files.
              Each service will create its own subdirectory here.
            '';
          };

          dataDir = lib.mkOption {
            type = lib.types.str;
            default = "/mnt/storage";
            description = ''
              Primary data directory for media files.
              This should point to your main storage location.
            '';
          };

          storageDir = lib.mkOption {
            type = lib.types.str;
            default = "/mnt/storage";
            description = ''
              Storage directory for large media files and backups.
              Often the same as dataDir but can be configured separately.
            '';
          };

          puid = lib.mkOption {
            type = lib.types.int;
            default = 5000;
            description = ''
              User ID for the media service user.
              All media services will run under this UID.
            '';
          };

          pgid = lib.mkOption {
            type = lib.types.int;
            default = 5000;
            description = ''
              Group ID for the media service group.
              All media services will run under this GID.
            '';
          };

          user = lib.mkOption {
            type = lib.types.str;
            default = "media";
            description = ''
              Username for the media service account.
              This user will own all media files and run all services.
            '';
          };

          group = lib.mkOption {
            type = lib.types.str;
            default = "media";
            description = ''
              Group name for the media service account.
            '';
          };

          tz = lib.mkOption {
            type = lib.types.str;
            default = "America/Toronto";
            description = ''
              Timezone for media services.
              Used for scheduling and timestamp display.
            '';
          };

          email = lib.mkOption {
            type = lib.types.str;
            default = "arsfeld@gmail.com";
            description = ''
              Email address for ACME certificate notifications
              and service administrative contacts.
            '';
          };

          domain = lib.mkOption {
            type = lib.types.str;
            default = "arsfeld.one";
            description = ''
              Primary domain for public-facing media services.
              SSL certificates will be issued for this domain and its subdomains.
            '';
          };

          linuxserverCaps = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = ["CHOWN" "DAC_OVERRIDE" "FOWNER" "SETUID" "SETGID" "KILL"];
            readOnly = true;
            description = ''
              Capabilities a linuxserver image needs (s6 starts as root and drops to
              PUID/PGID). It is the default for `container.hardening.caps` on those
              images; reuse it to extend the set instead of restating it.
            '';
          };

          tsDomain = lib.mkOption {
            type = lib.types.str;
            default = "bat-boa.ts.net";
            description = ''
              Tailscale domain for internal access to media services.
              Services will be accessible at <service>.<tsDomain>.
            '';
          };
        };

        config = lib.mkIf cfg.enable {
          sops.secrets.cloudflare =
            {
              sopsFile = config.constellation.sops.commonSopsFile;
            }
            // lib.optionalAttrs (config.security.acme.certs != {}) {
              owner = "acme";
              group = "acme";
            };

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

          security.acme.acceptTerms = true;

          security.acme.defaults = {
            email = cfg.email;
            dnsResolver = "1.1.1.1:53";
            dnsProvider = "cloudflare";
            environmentFile = config.sops.secrets.cloudflare.path;
          };
        };
      })
    ];
  };
}
