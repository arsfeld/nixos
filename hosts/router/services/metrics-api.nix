{
  config,
  lib,
  pkgs,
  ...
}: {
  # Create systemd service for the metrics API
  systemd.services.router-metrics-api = {
    description = "Router Metrics API Service";
    after = ["network.target"];
    wantedBy = ["multi-user.target"];

    serviceConfig = {
      Type = "simple";
      # Bind to localhost only since Caddy proxies to it
      ExecStart = "${pkgs.python3}/bin/python3 ${./metrics-api.py} --host localhost --port 8085";
      Restart = "always";
      RestartSec = 5;

      # Security hardening
      DynamicUser = true;
      PrivateTmp = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      NoNewPrivileges = true;

      # Allow reading system information
      PrivateDevices = false;
      ProtectKernelTunables = false;
      ProtectKernelModules = false;

      # Allow reading Kea DHCP leases
      ReadOnlyPaths = ["/var/lib/kea"];
      SupplementaryGroups = ["kea"];

      # Network capabilities for getting interface info
      AmbientCapabilities = ["CAP_NET_ADMIN" "CAP_NET_RAW"];
      CapabilityBoundingSet = ["CAP_NET_ADMIN" "CAP_NET_RAW"];
    };
  };

  # Ensure Python is available
  environment.systemPackages = with pkgs; [
    python3
  ];
}
