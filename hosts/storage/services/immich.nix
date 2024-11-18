{
  self,
  lib,
  config,
  pkgs,
  ...
}: let
  vars = config.vars;
in {
  services.redis.servers.immich = {
    enable = true;
    port = 60609;
    bind = "0.0.0.0";
    settings = {
      "protected-mode" = "no";
    };
  };

  virtualisation.oci-containers.containers = let
    immich-options = {
      image = "ghcr.io/immich-app/immich-server:release";
      environment = {
        PUID = vars.puid;
        PGID = vars.pgid;
        TZ = vars.tz;

        DB_HOSTNAME = "host.docker.internal";
        DB_USERNAME = "immich";
        DB_PASSWORD = "immich";
        DB_DATABASE_NAME = "immich";
        REDIS_HOSTNAME = "host.docker.internal";
        JWT_SECRET = "somelongrandomstring";
        DB_PORT = "5432";
        REDIS_PORT = "60609";
      };
      volumes = [
        "${vars.dataDir}/files/Immich:/usr/src/app/upload"
        "${vars.dataDir}/homes/arosenfeld/Takeout:/takeout"
      ];
      extraOptions = [
        "--add-host=host.docker.internal:host-gateway"
        "--link=immich-db"
        "--link=immich-machine-learning"
        "--device=/dev/dri"
      ];
    };
  in {
    immich-server =
      immich-options
      // {
        ports = ["15777:2283"];
      };

    immich-machine-learning = {
      image = "ghcr.io/immich-app/immich-machine-learning:release";
      volumes = [
        "${vars.configDir}/immich/model-cache:/cache"
      ];
    };

    immich-db = {
      image = "registry.hub.docker.com/tensorchord/pgvecto-rs:pg14-v0.2.0";
      environment = {
        POSTGRES_PASSWORD = "immich";
        POSTGRES_USER = "immich";
        POSTGRES_DB = "immich";
      };
      volumes = [
        "${vars.configDir}/immich/db:/var/lib/postgresql/data"
      ];
    };
  };
}
