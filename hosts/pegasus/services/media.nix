# Pegasus media services: Plex, Stash, mydia.
#
# These exist so the core media stack stays reachable from outside Tailscale
# (work laptop, etc.) while galactica is offline for the move. They are served
# at <service>.arsfeld.xyz via the gateway + Cloudflare tunnel.
#
# Auth note: galactica hosts Authelia/OIDC, which are unreachable while it is
# down. Every service therefore sets bypassAuth = true and relies on its own
# login:
#   - Plex   -> plex.tv accounts (no local auth needed)
#   - Stash  -> built-in login; SET A PASSWORD in the Stash setup wizard on
#               first launch, since the service is public.
#   - mydia  -> OIDC disabled (OIDC_ENABLED=false); built-in auth only.
#
# host = "localhost" points Caddy straight at the loopback service so we don't
# depend on hostname resolution or open extra firewall ports (all three use
# host networking).
{
  config,
  lib,
  self,
  ...
}: let
  mkService = import "${self}/modules/media/__mkService.nix" {inherit lib;};
  vars = config.media.config;
in
  lib.mkMerge [
    {
      # Phoenix/Guardian secrets for the pegasus mydia instance. This is a
      # fresh instance with its own database, so these are independent of
      # galactica's mydia-env (which also carries OIDC config we omit here).
      sops.secrets.mydia-env = {
        sopsFile = ../../../secrets/sops/pegasus.yaml;
        mode = "0444";
      };
    }

    # Plex. Keep the plexinc image so the existing /var/data/plex config (which
    # is plexinc-format, not linuxserver) keeps working.
    (mkService "plex" {
      port = 32400;
      image = "plexinc/pms-docker:latest";
      host = "localhost";
      bypassAuth = true;
      container = {
        exposePort = 32400;
        mediaVolumes = true;
        network = "host";
        devices = ["/dev/dri:/dev/dri"];
        environment.VERSION = "docker";
      };
    })

    # Stash. Public via bypassAuth -> protect it with Stash's own login.
    (mkService "stash" {
      port = 9999;
      image = "stashapp/stash:latest";
      host = "localhost";
      bypassAuth = true;
      container = {
        exposePort = 9999;
        configDir = "/root/.stash";
        mediaVolumes = true;
        network = "host";
        devices = ["/dev/dri:/dev/dri"];
      };
    })

    # mydia, stripped for pegasus: no download clients (rqbit/PIA live on
    # galactica), no FlareSolverr, OIDC disabled. Browse/manage the synced
    # library only.
    (mkService "mydia" {
      port = 4000;
      image = "ghcr.io/getmydia/mydia:master";
      host = "localhost";
      bypassAuth = true;
      container = {
        exposePort = 4000;
        mediaVolumes = true;
        network = "host";
        devices = ["/dev/dri:/dev/dri"];
        environment = {
          PHX_HOST = "mydia.arsfeld.xyz";
          PORT = "4000";
          TV_PATH = "/media/Series";
          MOVIES_PATH = "/media/Movies";
          OIDC_ENABLED = "false";
          ENABLE_REMOTE_ACCESS = "true";
          # FlareSolverr (flaresolverr service below) for Cloudflare-protected
          # indexers. Host-networked, so mydia reaches it on localhost.
          FLARESOLVERR_ENABLED = "true";
          FLARESOLVERR_URL = "http://localhost:8191";
          # Send grabs to the VPN-confined Transmission (transmission.nix).
          # mydia is host-networked, so it reaches Transmission on localhost:9091.
          # DOWNLOAD_CLIENT_1_PASSWORD comes from the mydia-env secret.
          DOWNLOAD_CLIENT_1_NAME = "transmission";
          DOWNLOAD_CLIENT_1_TYPE = "transmission";
          DOWNLOAD_CLIENT_1_ENABLED = "true";
          DOWNLOAD_CLIENT_1_PRIORITY = "1";
          DOWNLOAD_CLIENT_1_HOST = "localhost";
          DOWNLOAD_CLIENT_1_PORT = "9091";
          DOWNLOAD_CLIENT_1_USERNAME = "admin";
          DOWNLOAD_CLIENT_1_USE_SSL = "false";
          DOWNLOAD_CLIENT_1_DOWNLOAD_DIRECTORY = "/mnt/storage/media/Downloads";
          # Search via the local Prowlarr (media.nix). mydia is host-networked,
          # so Prowlarr is on localhost:9696. INDEXER_1_API_KEY is in mydia-env.
          INDEXER_1_NAME = "Prowlarr";
          INDEXER_1_TYPE = "prowlarr";
          INDEXER_1_ENABLED = "true";
          INDEXER_1_PRIORITY = "1";
          INDEXER_1_BASE_URL = "http://localhost:9696";
        };
        environmentFiles = [config.sops.secrets.mydia-env.path];
      };
    })

    # Prowlarr — indexer manager. Feeds indexers to mydia (add them in mydia as
    # Torznab feeds from Prowlarr). Public with bypassAuth -> set a Prowlarr
    # login on first launch, like Stash. The add-host lets Prowlarr reach the
    # host-networked FlareSolverr at http://host.containers.internal:8191.
    (mkService "prowlarr" {
      port = 9696;
      host = "localhost";
      bypassAuth = true;
      container = {
        exposePort = 9696;
        extraOptions = ["--add-host=host.containers.internal:host-gateway"];
      };
    })

    # FlareSolverr — solves Cloudflare challenges for indexers. Internal only
    # (no gateway entry): an unauthenticated FlareSolverr is an abusable proxy,
    # so it is not exposed publicly. Host-networked so it binds :8191 for mydia
    # (localhost) and Prowlarr (host.containers.internal).
    #
    # --dns is required: the host resolv.conf points only at Tailscale MagicDNS
    # (100.100.100.100), which Docker strips when generating resolv.conf for
    # host-networked containers, leaving FlareSolverr's headless Chrome with no
    # nameserver. Without this it fails every challenge with ERR_NAME_NOT_RESOLVED
    # and indexers like 1337x return zero results.
    (mkService "flaresolverr" {
      port = null;
      image = "ghcr.io/flaresolverr/flaresolverr:latest";
      container = {
        configDir = null;
        network = "host";
        extraOptions = ["--dns=1.1.1.1" "--dns=1.0.0.1"];
      };
    })

    {
      # Keep Plex's port open for direct LAN access / client discovery.
      networking.firewall.allowedTCPPorts = [32400];
      # Let bridge containers (e.g. Prowlarr) reach the host-networked
      # FlareSolverr at host.containers.internal:8191. Scoped to the podman
      # bridge so 8191 is not opened on LAN/Tailscale/public interfaces.
      networking.firewall.interfaces."podman0".allowedTCPPorts = [8191];
    }
  ]
