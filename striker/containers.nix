{
  lib,
  config,
  pkgs,
  nixpkgs,
  modulesPath,
  ...
}:
with lib; let
  configDir = "/var/data";
  dataDir = "/mnt/data";
  puid = "5000";
  pgid = "5000";
  tz = "America/Toronto";
in {
  containers.torrent = {
    ephemeral = true;
    autoStart = true;
    enableTun = true;
    privateNetwork = true;
    hostAddress = "192.168.100.1";
    localAddress = "192.168.100.2";

    forwardPorts = [
      {
        protocol = "tcp";
        hostPort = 9091;
        containerPort = 9091;
      }
    ];

    config = {
      config,
      pkgs,
      ...
    }: {
      services.transmission = {
        enable = true;
      };

      networking.firewall.allowedTCPPorts = [9091];
    };
  };
}
