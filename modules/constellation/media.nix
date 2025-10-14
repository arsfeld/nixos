# Constellation media server module
#
# This module configures a comprehensive media server stack including download
# automation, media organization, and streaming services. It uses containerized
# services for isolation and easy management.
#
# Key features:
# - Plex media server with hardware transcoding support
# - Automated media acquisition (*arr stack: Radarr, Sonarr, Bazarr, Prowlarr)
# - Download management (Autobrr, Pinchflat for YouTube)
# - Content discovery (Overseerr, Jackett, Flaresolverr)
# - Additional media services (Kavita for manga/comics, Stash)
# - Nextcloud for file storage and sharing
#
# Services are distributed across hosts:
# - Storage host: Media services, download automation, Plex
# - Cloud host: Public-facing services (formerly Ghost blog)
#
# All services are configured with appropriate volume mounts for persistent
# storage and media access, with hardware acceleration where supported.
{
  config,
  lib,
  self,
  pkgs,
  ...
}: let
  cfg = config.constellation.media;
  vars = config.media.config;
in {
  options.constellation.media = {
    enable = lib.mkOption {
      type = lib.types.bool;
      description = ''
        Enable the comprehensive media server stack.
        This includes Plex, the *arr suite, download automation,
        and various media management services.
      '';
      default = false;
    };
  };

  config = lib.mkIf cfg.enable {
    # Configure agenix environment files for Ghost (disabled for Zola migration)
    # age.secrets.ghost-smtp-env = lib.mkIf (builtins.any (host: host == config.networking.hostName) ["cloud"]) {
    #   file = "${self}/secrets/ghost-smtp-env.age";
    #   mode = "444";
    # };
    # age.secrets.ghost-session-env = lib.mkIf (builtins.any (host: host == config.networking.hostName) ["cloud"]) {
    #   file = "${self}/secrets/ghost-session-env.age";
    #   mode = "444";
    # };

    # Ohdio secrets
    age.secrets.ohdio-env = lib.mkIf (builtins.any (host: host == config.networking.hostName) ["storage"]) {
      file = "${self}/secrets/ohdio-env.age";
      mode = "444";
    };

    media.containers = let
      storageServices = {
        nextcloud = {
          listenPort = 443;
          volumes = [
            "${vars.storageDir}/files/Nextcloud:/data"
          ];
          settings = {
            insecureTls = true;
          };
        };

        overseerr = {
          listenPort = 5055;
        };

        jackett = {
          listenPort = 9117;
        };

        bazarr = {
          listenPort = 6767;
          mediaVolumes = true;
        };

        radarr = {
          listenPort = 7878;
          mediaVolumes = true;
        };

        sonarr = {
          listenPort = 8989;
          mediaVolumes = true;
        };

        prowlarr = {
          listenPort = 9696;
        };

        autobrr = {
          image = "ghcr.io/autobrr/autobrr:latest";
          listenPort = 7474;
        };

        pinchflat = {
          image = "ghcr.io/kieraneglin/pinchflat:latest";
          listenPort = 8945;
          volumes = [
            "${vars.storageDir}/media/Pinchflat:/downloads"
          ];
        };

        plex = {
          environment = {
            VERSION = "latest";
          };
          mediaVolumes = true;
          network = "host";
          devices = ["/dev/dri:/dev/dri"];
        };

        jellyfin = {
          listenPort = 8096;
          mediaVolumes = true;
          devices = ["/dev/dri:/dev/dri"];
          environment = {
            JELLYFIN_PublishedServerUrl = "https://jellyfin.arsfeld.one";
          };
          settings = {
            funnel = true;
            bypassAuth = true;
          };
        };

        stash = {
          image = "stashapp/stash:latest";
          configDir = "/root/.stash";
          mediaVolumes = true;
          network = "host";
          devices = ["/dev/dri:/dev/dri"];
        };

        flaresolverr = {
          image = "ghcr.io/flaresolverr/flaresolverr:latest";
          listenPort = 8191;
          exposePort = 8191;
          configDir = null;
        };

        kavita = {
          listenPort = 5000;
          volumes = [
            "${vars.storageDir}/media/Manga:/data"
          ];
        };

        actual = {
          image = "ghcr.io/actualbudget/actual-server:latest";
          listenPort = 5006;
          volumes = [
            "${vars.storageDir}/data/actual:/data"
          ];
          settings = {
            bypassAuth = true;
            funnel = true;
          };
        };

        ohdio = {
          image = "ghcr.io/arsfeld/ohdio:latest";
          listenPort = 4000;
          volumes = [
            "${vars.storageDir}/data/ohdio:/config"
          ];
          environment = {
            PHX_HOST = "ohdio.bat-boa.ts.net";
            PORT = "4000";
            MIX_ENV = "prod";
            DATABASE_PATH = "/config/db/ohdio_prod.db";
            STORAGE_PATH = "/config/downloads";
            MAX_CONCURRENT_DOWNLOADS = "3";
          };
          environmentFiles = [
            config.age.secrets.ohdio-env.path
          ];
          settings = {
            bypassAuth = true;
            funnel = true;
          };
        };
      };

      cloudServices = {
        # Ghost disabled in favor of Zola static site
        # ghost = {
        #   image = "ghost:5";
        #   volumes = ["/var/lib/ghost/content:/var/lib/ghost/content"];
        #   configDir = null;
        #   environment = {
        #     url = "https://blog.arsfeld.dev";
        #     database__client = "sqlite3";
        #     database__connection__filename = "/var/lib/ghost/content/data/ghost.db";
        #     database__useNullAsDefault = "true";
        #
        #     # Email configuration for Ghost admin authentication (matches constellation.email)
        #     mail__transport = "SMTP";
        #     mail__from = "admin@rosenfeld.one";
        #     mail__options__host = "smtp.purelymail.com";
        #     mail__options__port = "587";
        #     mail__options__secure = "false";
        #     mail__options__auth__user = "alex@rosenfeld.one";
        #     mail__options__auth__pass = "$SMTP_PASSWORD";
        #
        #     # Session configuration for admin authentication
        #     auth__session__secret = "$GHOST_SESSION_SECRET";
        #
        #     # Disable staff device verification
        #     security__staffDeviceVerification = "false";
        #   };
        #   listenPort = 2368;
        #   environmentFiles = [
        #     config.age.secrets.ghost-smtp-env.path
        #     config.age.secrets.ghost-session-env.path
        #   ];
        # };

        # OwnTracks handled by hosts/cloud/services/owntracks.nix
      };

      # Apply the storage host to all services
      addHost = host: name: service: service // {host = host;};
    in
      lib.mapAttrs (addHost "storage") storageServices // lib.mapAttrs (addHost "cloud") cloudServices;
  };
}
