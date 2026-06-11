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
        };
        environmentFiles = [config.sops.secrets.mydia-env.path];
      };
    })

    # Keep Plex's port open for direct LAN access / client discovery.
    {networking.firewall.allowedTCPPorts = [32400];}
  ]
