{
  config,
  lib,
  pkgs,
  ...
}: let
  # Validate the Python script at build time
  routerDashboardScript =
    pkgs.runCommand "router-dashboard-validated" {
      buildInputs = with pkgs; [
        python3
        python3.pkgs.pyflakes
        python3.pkgs.flake8
        python3.pkgs.pylint
      ];
      src = ./router-dashboard.py;
    } ''
      # Copy the script
      cp $src router-dashboard.py

      # Run Python syntax check (this will fail the build on syntax errors)
      echo "Checking Python syntax..."
      if ! python3 -m py_compile router-dashboard.py; then
        echo "ERROR: Python syntax check failed!"
        exit 1
      fi

      # Check for undefined variables and other basic errors
      echo "Checking for undefined names..."
      if ! python3 -m pyflakes router-dashboard.py; then
        echo "ERROR: Found undefined names or other errors!"
        exit 1
      fi

      # Run flake8 for style and basic errors (ignore line length and complexity)
      # This is informational only, won't fail the build
      echo "Running flake8 (informational)..."
      flake8 --ignore=E501,C901,W503,E402 --max-line-length=120 router-dashboard.py || true

      # Check for common errors with pylint (informational only)
      echo "Running pylint (informational)..."
      pylint --errors-only --disable=import-error,no-member router-dashboard.py || true

      # If we get here, the script is valid
      echo "Python validation successful!"
      cp router-dashboard.py $out
    '';
in {
  # Create systemd service for the router dashboard
  systemd.services.router-dashboard = {
    description = "Router Dashboard Service";
    after = ["network.target"];
    wantedBy = ["multi-user.target"];

    # Add required packages to the service's PATH
    path = with pkgs; [
      iputils # for ping
      iproute2 # for ip command
      conntrack-tools # for conntrack
    ];

    serviceConfig = {
      Type = "simple";
      # Bind to localhost only since Caddy proxies to it
      ExecStart = "${pkgs.python3}/bin/python3 -u ${routerDashboardScript} --host localhost --port 8085";
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

      # Allow reading Kea DHCP leases and proc files
      ReadOnlyPaths = [
        "/var/lib/kea"
        "/proc/net"
        "/proc/uptime"
        "/proc/loadavg"
        "/proc/stat"
        "/proc/meminfo"
      ];
      SupplementaryGroups = ["kea"];

      # Allow writing hostname cache
      ReadWritePaths = ["/tmp"];

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
