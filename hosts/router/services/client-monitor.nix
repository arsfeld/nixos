{
  config,
  lib,
  pkgs,
  ...
}: {
  # Create systemd service for client monitoring
  systemd.services.router-client-monitor = {
    description = "Router Client Connection Monitor";
    after = ["network.target" "kea-dhcp4.service"];
    wantedBy = ["multi-user.target"];

    serviceConfig = {
      Type = "simple";
      ExecStart = "${pkgs.python3}/bin/python3 ${./client-monitor.py}";
      # Publisher credential for authenticated ntfy.arsfeld.one publishes.
      # Same sops secret as ntfy-webhook — systemd reads the file as root
      # so DynamicUser is fine.
      EnvironmentFile = config.sops.secrets."ntfy-publisher-env".path;
      Restart = "always";
      RestartSec = 30;

      # Security hardening
      DynamicUser = true;
      PrivateTmp = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      NoNewPrivileges = true;

      # State directory for known clients
      StateDirectory = "router-client-monitor";
      StateDirectoryMode = "0700";

      # Allow reading system information
      PrivateDevices = false;
      ProtectKernelTunables = false;
      ProtectKernelModules = false;

      # Allow reading Kea DHCP leases
      ReadOnlyPaths = ["/var/lib/kea"];
      SupplementaryGroups = ["kea"];

      # Network access for ntfy.sh and hostname resolution
      PrivateNetwork = false;
      RestrictAddressFamilies = ["AF_INET" "AF_INET6" "AF_UNIX"];

      # Network capabilities for getting interface info
      AmbientCapabilities = ["CAP_NET_ADMIN" "CAP_NET_RAW"];
      CapabilityBoundingSet = ["CAP_NET_ADMIN" "CAP_NET_RAW"];

      # Environment
      Environment = [
        "PYTHONUNBUFFERED=1"
      ];
    };
  };

  # Ensure Python is available
  environment.systemPackages = with pkgs; [
    python3
  ];
}
