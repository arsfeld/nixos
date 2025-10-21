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

    # Qui OIDC secrets
    age.secrets.qui-oidc-env = lib.mkIf (builtins.any (host: host == config.networking.hostName) ["storage"]) {
      file = "${self}/secrets/qui-oidc-env.age";
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
            bypassAuth = true;
          };
        };

        overseerr = {
          listenPort = 5055;
          settings.bypassAuth = true;
        };

        jackett = {
          listenPort = 9117;
          settings.bypassAuth = true;
        };

        bazarr = {
          listenPort = 6767;
          mediaVolumes = true;
          settings.bypassAuth = true;
        };

        radarr = {
          listenPort = 7878;
          mediaVolumes = true;
          settings.bypassAuth = false; # Requires Authelia auth (API endpoints bypassed via Authelia rules)
        };

        sonarr = {
          listenPort = 8989;
          mediaVolumes = true;
          settings.bypassAuth = false; # Requires Authelia auth (API endpoints bypassed via Authelia rules)
        };

        prowlarr = {
          listenPort = 9696;
          settings.bypassAuth = true;
        };

        autobrr = {
          image = "ghcr.io/autobrr/autobrr:latest";
          listenPort = 7474;
          settings.bypassAuth = true;
        };

        pinchflat = {
          image = "ghcr.io/kieraneglin/pinchflat:latest";
          listenPort = 8945;
          volumes = [
            "${vars.storageDir}/media/Pinchflat:/downloads"
          ];
          settings.bypassAuth = true;
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
            bypassAuth = true;
            funnel = true;
          };
        };

        stash = {
          image = "stashapp/stash:latest";
          listenPort = 9999;
          configDir = "/root/.stash";
          mediaVolumes = true;
          network = "host";
          devices = ["/dev/dri:/dev/dri"];
          settings.funnel = true;
        };

        flaresolverr = {
          image = "ghcr.io/flaresolverr/flaresolverr:latest";
          listenPort = 8191;
          exposePort = 8191;
          configDir = null;
          settings.bypassAuth = true;
        };

        kavita = {
          listenPort = 5000;
          volumes = [
            "${vars.storageDir}/media/Manga:/data"
          ];
          settings.bypassAuth = true;
        };

        actual = {
          image = "ghcr.io/actualbudget/actual-server:latest";
          listenPort = 5006;
          volumes = [
            "${vars.storageDir}/data/actual:/data"
          ];
          settings.bypassAuth = true;
        };

        ohdio = {
          image = "ghcr.io/arsfeld/ohdio:latest";
          listenPort = 4000;
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
          settings.bypassAuth = true;
        };

        # qBittorrent with integrated WireGuard VPN
        qbittorrent = {
          image = "ghcr.io/hotio/qbittorrent";
          listenPort = 8080; # qBittorrent web UI port
          mediaVolumes = true; # Mount media directories
          extraOptions = ["--cap-add=NET_ADMIN"]; # Required for WireGuard VPN setup
          environment = {
            UMASK = "002";
            VPN_ENABLED = "true";
            VPN_CONF = "wg0";
            VPN_PROVIDER = "generic";
            # Container auto-detects Podman network (10.88.0.0/16) for LAN access
            # AirVPN port forwarding configuration
            VPN_AUTO_PORT_FORWARD = "55473"; # Static port from AirVPN
          };
          settings = {
            bypassAuth = true; # Has built-in authentication
            funnel = true; # Enable public internet access to qbittorrent.bat-boa.ts.net (not just tailnet)
          };
        };

        # qui - Modern qBittorrent web UI with multi-instance support
        qui = {
          image = "ghcr.io/autobrr/qui";
          listenPort = 7476;
          environment = {
            QUI__HOST = "0.0.0.0";
            QUI__PORT = "7476";
            # OIDC authentication configuration using Authelia
            QUI__OIDC_ENABLED = "true";
            QUI__OIDC_ISSUER = "https://auth.arsfeld.one";
            QUI__OIDC_CLIENT_ID = "qui";
            QUI__OIDC_REDIRECT_URL = "https://qui.arsfeld.one/api/auth/oidc/callback";
            QUI__OIDC_DISABLE_BUILT_IN_LOGIN = "false"; # Keep local login as fallback
          };
          environmentFiles = [
            config.age.secrets.qui-oidc-env.path
          ];
          extraOptions = [
            "--no-healthcheck" # Disable container health check to prevent activation failures
          ];
          settings = {
            bypassAuth = true; # qui has its own authentication
            funnel = true; # Enable public internet access to qui.bat-boa.ts.net (not just tailnet)
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
