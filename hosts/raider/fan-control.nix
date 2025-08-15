# NZXT H1 V2 Dynamic Fan Control
# Python-based fan control with exponential curve and anti-oscillation
{pkgs, ...}: {
  # Service to manage dynamic fan curves using Python script
  systemd.services.nzxt-fan-control = {
    description = "NZXT H1 V2 Dynamic Fan Control";
    after = ["multi-user.target"];
    wantedBy = ["multi-user.target"];

    serviceConfig = {
      Type = "simple";
      Restart = "on-failure";
      RestartSec = "10";

      # Run the Python fan control script
      ExecStart = "${pkgs.python3}/bin/python3 ${./nzxt-fan-control.py}";

      # Run as root to access hardware
      User = "root";

      # Logging
      StandardOutput = "journal";
      StandardError = "journal";
    };

    path = with pkgs; [
      liquidctl
      lm_sensors
      python3
    ];
  };

  # Add required tools for fan control
  environment.systemPackages = with pkgs; [
    liquidctl # For device detection and manual control
    lm_sensors # For temperature monitoring
  ];
}
