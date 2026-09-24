# NZXT H1 V2 fan control: smoothed curves, see fan-control/fan_control.py
{pkgs, ...}: {
  systemd.services.nzxt-fan-control = {
    description = "NZXT H1 V2 Dynamic Fan Control";
    after = ["multi-user.target"];
    wantedBy = ["multi-user.target"];

    serviceConfig = {
      Type = "simple";
      # The device holds its last duty if this dies, so always come back.
      Restart = "always";
      RestartSec = "10";
      ExecStart = "${pkgs.python3}/bin/python3 ${./fan-control/fan_control.py}";
      # Run as root to access hardware
      User = "root";
    };

    path = [pkgs.liquidctl];
  };

  # For device detection and manual control
  environment.systemPackages = with pkgs; [
    liquidctl
    lm_sensors
  ];
}
