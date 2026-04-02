{
  config,
  pkgs,
  lib,
  ...
}: let
  httpPort = 3333;
  dhtPort = 3334;
in {
  sops.secrets."bitmagnet-env" = {};

  media.containers.bitmagnet = {
    image = "ghcr.io/bitmagnet-io/bitmagnet:latest";
    listenPort = httpPort;
    exposePort = httpPort;
    environmentFiles = [
      config.sops.secrets."bitmagnet-env".path
    ];
    environment = {
      POSTGRES_HOST = "host.containers.internal";
      POSTGRES_NAME = "bitmagnet";
      POSTGRES_USER = "bitmagnet";
    };
    extraOptions = [
      "--add-host=host.containers.internal:host-gateway"
      "--publish=${toString dhtPort}:${toString dhtPort}/tcp"
      "--publish=${toString dhtPort}:${toString dhtPort}/udp"
    ];
  };

  # media.containers has no cmd option; set it separately (module system merges)
  virtualisation.oci-containers.containers.bitmagnet.cmd = [
    "worker"
    "run"
    "--keys=http_server"
    "--keys=queue_server"
    "--keys=dht_crawler"
  ];

  # Ensure PostgreSQL is ready before starting bitmagnet
  systemd.services.podman-bitmagnet = {
    after = ["postgresql.service"];
    requires = ["postgresql.service"];
    serviceConfig = {
      Nice = 19;
      CPUWeight = 10;
      IOWeight = 10;
    };
  };

  media.gateway.services.bitmagnet.exposeViaTailscale = true;
}
