{
  config,
  lib,
  pkgs,
  ...
}: {
  # TP-Link Omada Controller - Network device management
  # Provides centralized management for TP-Link Omada network devices
  # (access points, switches, routers) via web interface
  #
  # Using native NixOS service instead of Docker for better integration
  # and performance. Version 6.0.0.24 with MongoDB 6.0 for non-AVX CPU
  # compatibility (router CPU: Celeron N5105 lacks AVX support).

  constellation.omada-controller = {
    enable = true;

    # Use MongoDB 6.0 for non-AVX CPU compatibility
    # The Celeron N5105 CPU lacks AVX support required by MongoDB 8+
    useMongoDb6 = true;

    # Default ports
    httpPort = 8088; # HTTP web interface
    httpsPort = 8043; # HTTPS web interface

    # Open required firewall ports
    openFirewall = true;
  };

  # Note: Web interface will be accessible on port 8043 (HTTPS) and 8088 (HTTP)
  # Default credentials: admin/admin (change on first login)
  #
  # Data is stored in /var/lib/omada instead of /var/data/omada
  # Migration from Docker: Manual export/import of settings required
}
