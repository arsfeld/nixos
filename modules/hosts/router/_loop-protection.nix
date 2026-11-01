{
  config,
  lib,
  pkgs,
  ...
}: let
  # Script to monitor and disable looping ports
  loopMonitor = pkgs.writeScript "loop-monitor" ''
    #!${pkgs.bash}/bin/bash

    # Monitor kernel messages for loop detection
    ${pkgs.systemd}/bin/journalctl -f -n0 -k | while read line; do
      if echo "$line" | grep -q "received packet on enp4s0 with own address as source"; then
        echo "Loop detected on enp4s0, disabling port temporarily"
        ${pkgs.iproute2}/bin/ip link set enp4s0 down
        sleep 60
        echo "Re-enabling enp4s0"
        ${pkgs.iproute2}/bin/ip link set enp4s0 up
        ${pkgs.iproute2}/bin/ip link set enp4s0 master br-lan
      fi
    done
  '';
in {
  # Create a systemd service to monitor for loops
  systemd.services.bridge-loop-monitor = {
    description = "Monitor and protect against bridge loops";
    after = ["network.target"];
    wantedBy = ["multi-user.target"];

    serviceConfig = {
      Type = "simple";
      ExecStart = "${loopMonitor}";
      Restart = "always";
      RestartSec = 5;
    };
  };

  # More aggressive STP settings
  systemd.network.netdevs."20-br-lan".bridgeConfig = lib.mkForce {
    STP = true;
    ForwardDelaySec = 2; # Faster convergence
    HelloTimeSec = 1; # More frequent BPDUs
    MaxAgeSec = 6; # Faster detection of topology changes
    Priority = 0; # Make this bridge the root bridge
  };

  # More strict configuration for lan2 port
  systemd.network.networks."30-lan2".bridgeConfig = lib.mkForce {
    HairPin = false;
    FastLeave = true;
    Cost = 100; # Higher cost makes this port less preferred
    Priority = 32; # Valid range is 0-63
  };

  # Add iptables rules to detect and log MAC spoofing
  networking.nftables.ruleset = lib.mkAfter ''
    table bridge filter {
      chain input {
        type filter hook input priority -200; policy accept;

        # Log packets with bridge's own MAC as source
        ether saddr 6e:a3:1e:6b:32:6b log prefix "LOOP-DETECTED: " counter drop
      }
    }
  '';
}
