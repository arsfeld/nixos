{
  lib,
  config,
  pkgs,
  ...
}: let
  vars = config.media.config;
in {
  sops.secrets.tailscale-key.sopsFile = config.constellation.sops.commonSopsFile;
  sops.secrets.tailscale-env = {};
  sops.secrets.romm-env = {};

  # tsnsrv re-enabled - caddy-tailscale causing high CPU usage and TLS cert issues (task-48)
  # Reverting to tsnsrv until caddy-tailscale issues are resolved
  services.tsnsrv = {
    enable = true;
    separateProcesses = true; # Create individual systemd service per tsnsrv service
    prometheusAddr = "127.0.0.1:9500"; # Moved from 9099 to avoid conflict with OpenCloud (uses 9100-9300)
    defaults = {
      tags = ["tag:service"];
      authKeyPath = config.sops.secrets.tailscale-key.path;
      ephemeral = true;
    };
  };

  media.services.romm = {
    # Not probe-verified (the probe could not run it without secrets/DB); caps come from the image's entrypoint. The docker-entrypoint.sh only ends with 'exec "$@"' and /init is s6, whose commands were not read, so all caps are precautionary.
    # CHOWN: precautionary (s6 init likely chowns its dirs).
    # DAC_OVERRIDE, FOWNER: precautionary (/romm dirs are root-owned here; media-owned files elsewhere).
    # SETUID, SETGID: precautionary (valkey/nginx/gunicorn workers drop privileges).
    container.hardening.caps = ["CHOWN" "DAC_OVERRIDE" "FOWNER" "SETUID" "SETGID"];
    port = 8080;
    image = "rommapp/romm:latest";
    container = {
      exposePort = 8998;
      configDir = null;
      environment = {
        DB_HOST = "host.docker.internal";
        DB_NAME = "romm";
        DB_USER = "romm";
      };
      environmentFiles = [
        config.sops.secrets.romm-env.path
      ];
      volumes = [
        "${vars.configDir}/romm/resources:/romm/resources"
        "${vars.configDir}/romm/redis:/redis-data"
        "${vars.configDir}/romm/assets:/romm/assets"
        "${vars.configDir}/romm/config:/romm/config"
        "${vars.dataDir}/files/Emulation:/romm/library"
      ];
      extraOptions = [
        "--add-host=host.docker.internal:host-gateway"
      ];
    };
  };

  media.services.speedtest = {
    # Probe-verified: extends the linuxserver default set.
    # NET_BIND_SERVICE: nginx binds port 80 in-container (bind() permission denied without it).
    container.hardening.caps = vars.linuxserverCaps ++ ["NET_BIND_SERVICE"];
    port = 80;
    image = "lscr.io/linuxserver/speedtest-tracker:latest";
    container = {
      exposePort = 8765;
      environment = {
        APP_KEY = "base64:MGxwY3Y1OHZpMnJwN2s2dGtkdnJ6dm40ODEwd3J4eGI=";
        DB_CONNECTION = "sqlite";
        SPEEDTEST_SCHEDULE = "5 4 * * *";
      };
    };
  };

  media.services.filestash = {
    port = 8334;
    image = "machines/filestash";
    container = {
      exposePort = 8334;
      configDir = "/app/data/state";
      volumes = [
        "${vars.dataDir}/media:/mnt/data/media"
        "${vars.dataDir}/files:/mnt/data/files"
      ];
    };
  };

  # headscale-ui has no gateway entry: bind directly to host port 9899.
  media.services.headscale-ui = {
    image = "ghcr.io/gurucomputing/headscale-ui:latest";
    container = {
      configDir = null;
      extraOptions = ["--publish=9899:80"];
    };
  };
}
