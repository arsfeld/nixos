{
  config,
  pkgs,
  ...
}: let
  httpPort = 3333;
  dhtPort = 3334;
  bitmagnetConfig = pkgs.writeText "bitmagnet-config.yml" ''
    dht_crawler:
      # Upstream default is 100, which barely limits anything: 86% of the 103M
      # rows in torrent_files came from torrents holding 11-100 files, and the
      # table had grown to 41G (14G heap + 27G indexes) on a 460G root pool.
      # At 20, torrents above the threshold get files_status=over_threshold and
      # no file rows -- the same path bitmagnet already takes for >100-file
      # torrents. They stay searchable; only the per-file listing is lost.
      save_files_threshold: 20
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
