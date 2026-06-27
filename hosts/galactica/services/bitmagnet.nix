{
  config,
  pkgs,
  ...
}: let
  httpPort = 3333;
  dhtPort = 3334;
  bitmagnetConfig = pkgs.writeText "bitmagnet-config.yml" ''
    classifier:
      delete_xxx: true
      flags:
        delete_content_types:
          - xxx
          - music
          - ebook
  '';
in {
  sops.secrets."bitmagnet-env" = {};

  media.services.bitmagnet = {
    port = httpPort;
    image = "ghcr.io/bitmagnet-io/bitmagnet:latest";
    tailscaleExposed = true;
    container = {
      exposePort = httpPort;
      cmd = [
        "worker"
        "run"
        "--keys=http_server"
        "--keys=queue_server"
        "--keys=dht_crawler"
      ];
      environmentFiles = [
        config.sops.secrets."bitmagnet-env".path
      ];
      environment = {
        POSTGRES_HOST = "host.containers.internal";
        POSTGRES_NAME = "bitmagnet";
        POSTGRES_USER = "bitmagnet";
      };
      volumes = [
        "${bitmagnetConfig}:/root/.config/bitmagnet/config.yml:ro"
      ];
      extraOptions = [
        "--add-host=host.containers.internal:host-gateway"
        "--publish=${toString dhtPort}:${toString dhtPort}/tcp"
        "--publish=${toString dhtPort}:${toString dhtPort}/udp"
      ];
    };
    database.postgres = true;
  };

  # Resource limits for bitmagnet's heavy DHT crawler. The postgresql ordering is
  # also supplied by database.postgres (after/wants); the after/requires retained
  # here keep the original strong dependency.
  systemd.services.podman-bitmagnet = {
    after = ["postgresql.service"];
    requires = ["postgresql.service"];
    serviceConfig = {
      Nice = 19;
      CPUWeight = 10;
      IOWeight = 10;
    };
  };
}
