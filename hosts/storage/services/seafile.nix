{
  config,
  pkgs,
  ...
}: let
  vars = config.media.config;
  dataDir = "/mnt/storage/data/Seafile";
in {
  media.gateway.services.seafile = {
    port = 10080;
    settings.bypassAuth = true;
    exposeViaTailscale = true;
  };

  sops.secrets.seafile-env = {};

  systemd.tmpfiles.rules = [
    "d ${dataDir} 0750 ${vars.user} ${vars.group} -"
  ];

  virtualisation.oci-containers.containers.seafile = {
    image = "seafileltd/seafile-mc:13.0-latest";
    environment = {
      SEAFILE_SERVER_HOSTNAME = "seafile.arsfeld.one";
      SEAFILE_SERVER_PROTOCOL = "https";
      TIME_ZONE = "America/Toronto";
      SEAFILE_MYSQL_DB_HOST = "host.containers.internal";
      SEAFILE_MYSQL_DB_USER = "seafile";
      SEAFILE_MYSQL_DB_CCNET_DB_NAME = "ccnet_db";
      SEAFILE_MYSQL_DB_SEAFILE_DB_NAME = "seafile_db";
      SEAFILE_MYSQL_DB_SEAHUB_DB_NAME = "seahub_db";
      NON_ROOT = "false";
      REDIS_HOST = "host.containers.internal";
      REDIS_PORT = "6379";
    };
    environmentFiles = [
      config.sops.secrets.seafile-env.path
    ];
    volumes = [
      "${dataDir}:/shared"
    ];
    ports = ["10080:80"];
    extraOptions = [
      "--add-host=host.containers.internal:host-gateway"
    ];
  };

  systemd.services.podman-seafile = {
    after = ["mysql.service" "redis-seafile.service" "seafile-db-setup.service"];
    requires = ["mysql.service" "redis-seafile.service" "seafile-db-setup.service"];
  };
}
