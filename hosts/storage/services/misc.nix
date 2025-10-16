{
  self,
  lib,
  config,
  pkgs,
  ...
}: let
  vars = config.media.config;
in {
  age.secrets.tailscale-key.file = "${self}/secrets/tailscale-key.age";
  age.secrets.tailscale-env.file = "${self}/secrets/tailscale-env.age";
  age.secrets.romm-env.file = "${self}/secrets/romm-env.age";

  # tsnsrv disabled - replaced by Caddy with Tailscale plugin (single node vs 64 nodes)
  # This reduces CPU usage from 60.5% to ~2-5%
  services.tsnsrv.enable = false;

  virtualisation.oci-containers.containers = {
    romm = {
      image = "rommapp/romm:latest";
      environment = {
        DB_HOST = "host.docker.internal";
        DB_NAME = "romm";
        DB_USER = "romm";
      };
      environmentFiles = [
        config.age.secrets.romm-env.path
      ];
      volumes = [
        "${vars.configDir}/romm/resources:/romm/resources" # Resources fetched from IGDB (covers, screenshots, etc.)
        "${vars.configDir}/romm/redis:/redis-data" # Cached data for background tasks
        "${vars.configDir}/romm/assets:/romm/assets" # Uploaded saves, states, etc.
        "${vars.configDir}/romm/config:/romm/config" # Path where config.yml is stored
        "${vars.dataDir}/files/Emulation:/romm/library"
      ];
      ports = [
        "8998:8080"
      ];
      extraOptions = [
        "--add-host"
        "host.docker.internal:host-gateway"
      ];
    };

    watchyourlan = {
      volumes = ["/var/lib/watchyourlan:/data/WatchYourLAN"];
      environment = {
        IFACES = "enp4s0";
        TZ = "America/Toronto";
      };
      image = "aceberg/watchyourlan";
      extraOptions = [
        "--network=host"
      ];
    };

    speedtest = {
      image = "lscr.io/linuxserver/speedtest-tracker:latest";
      volumes = ["${vars.configDir}/speedtest:/config"];
      ports = ["8765:80"];
      environment = {
        "APP_KEY" = "base64:MGxwY3Y1OHZpMnJwN2s2dGtkdnJ6dm40ODEwd3J4eGI=";
        "DB_CONNECTION" = "sqlite";
        "SPEEDTEST_SCHEDULE" = "5 4 * * *";
      };
    };

    # netbootxyz = {
    #   image = "lscr.io/linuxserver/netbootxyz:latest";
    #   environment = {
    #     PUID = vars.puid;
    #     PGID = vars.pgid;
    #     TZ = vars.tz;
    #     # - MENU_VERSION=1.9.9 #optional
    #     # - PORT_RANGE=30000:30010 #optional
    #     # - SUBFOLDER=/ #optional
    #   };
    #   volumes = [
    #     "${vars.configDir}/netbootxyz:/config"
    #     "${vars.dataDir}/files/ISO:/assets"
    #   ];
    #   ports = [
    #     "3000:3000"
    #     "69:69/udp"
    #     "8080:80"
    #   ];
    # };

    # photoprism = {
    #   image = "photoprism/photoprism:latest";
    #   ports = ["2342:2342"];
    #   environment = {
    #     PHOTOPRISM_SITE_URL = "https://photoprism.arsfeld.one/";
    #     PHOTOPRISM_UPLOAD_NSFW = "true";
    #     PHOTOPRISM_ADMIN_PASSWORD = "password";
    #   };
    #   volumes = [
    #     "${vars.configDir}/photoprism:/photoprism/storage"
    #     "/home/arosenfeld/Pictures:/photoprism/originals"
    #   ];
    #   extraOptions = [
    #     "--security-opt"
    #     "seccomp=unconfined"
    #     "--security-opt"
    #     "apparmor=unconfined"
    #   ];
    # };

    filestash = {
      image = "machines/filestash";
      ports = ["8334:8334"];
      volumes = [
        "${vars.configDir}/filestash:/app/data/state"
        "${vars.dataDir}/media:/mnt/data/media"
        "${vars.dataDir}/files:/mnt/data/files"
      ];
    };

    headscale-ui = {
      image = "ghcr.io/gurucomputing/headscale-ui:latest";
      ports = [
        "9899:80"
      ];
    };
  };
}
