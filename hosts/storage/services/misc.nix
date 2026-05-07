{
  self,
  lib,
  config,
  pkgs,
  ...
}: let
  mkService = import "${self}/modules/media/__mkService.nix" {inherit lib;};
  vars = config.media.config;
in
  lib.mkMerge [
    {
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
    }

    (mkService "romm" {
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
    })

    (mkService "speedtest" {
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
    })

    (mkService "filestash" {
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
    })

    # headscale-ui has no gateway entry: bind directly to host port 9899.
    (mkService "headscale-ui" {
      image = "ghcr.io/gurucomputing/headscale-ui:latest";
      container = {
        configDir = null;
        extraOptions = ["--publish=9899:80"];
      };
    })
  ]
