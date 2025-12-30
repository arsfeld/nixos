# Plex Media Server for cottage
#
# This provides a local Plex instance for media synced from storage.
# Uses Intel QuickSync for hardware transcoding.
{
  config,
  pkgs,
  lib,
  ...
}: let
  # Plex configuration
  plexConfig = "/var/data/plex";
  mediaDir = "/mnt/storage/media";
in {
  # Create config directory
  systemd.tmpfiles.rules = [
    "d ${plexConfig} 0755 root root -"
  ];

  # Plex container
  virtualisation.oci-containers.containers.plex = {
    image = "plexinc/pms-docker:latest";
    autoStart = true;

    # Host networking for client discovery
    extraOptions = [
      "--network=host"
      # GPU access for Intel QuickSync
      "--device=/dev/dri:/dev/dri"
    ];

    environment = {
      TZ = "America/Toronto";
      VERSION = "docker";
      PLEX_CLAIM = ""; # Set this manually on first run if needed
    };

    volumes = [
      "${plexConfig}:/config"
      "${mediaDir}:/media:ro"
    ];
  };

  # Open Plex port (32400) - already in host network
  networking.firewall.allowedTCPPorts = [32400];
}
