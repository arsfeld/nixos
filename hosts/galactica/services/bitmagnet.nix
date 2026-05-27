{
  self,
  config,
  pkgs,
  lib,
  ...
}: let
  mkService = import "${self}/modules/media/__mkService.nix" {inherit lib;};
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
in
  lib.mkMerge [
    {sops.secrets."bitmagnet-env" = {};}

    (mkService "bitmagnet" {
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
    })

    {
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
    }
  ]
