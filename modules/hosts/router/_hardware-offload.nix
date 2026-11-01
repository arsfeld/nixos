# Hardware offloading configuration for network interfaces
# Enables TSO, GSO, GRO, and other NIC offloading features
{
  config,
  lib,
  pkgs,
  ...
}: let
  interfaces = config.router.interfaces;

  # Helper function to generate ethtool commands for an interface
  offloadScript = iface: ''
    echo "Configuring hardware offload for ${iface}..."

    # Checksum offloading
    ${pkgs.ethtool}/bin/ethtool -K ${iface} rx-checksum on 2>/dev/null || true
    ${pkgs.ethtool}/bin/ethtool -K ${iface} tx-checksum-ipv4 on 2>/dev/null || true
    ${pkgs.ethtool}/bin/ethtool -K ${iface} tx-checksum-ipv6 on 2>/dev/null || true
    ${pkgs.ethtool}/bin/ethtool -K ${iface} tx-checksum-ip-generic on 2>/dev/null || true

    # Segmentation offloading
    ${pkgs.ethtool}/bin/ethtool -K ${iface} tso on 2>/dev/null || true         # TCP Segmentation Offload
    ${pkgs.ethtool}/bin/ethtool -K ${iface} gso on 2>/dev/null || true         # Generic Segmentation Offload
    ${pkgs.ethtool}/bin/ethtool -K ${iface} gro on 2>/dev/null || true         # Generic Receive Offload
    ${pkgs.ethtool}/bin/ethtool -K ${iface} lro off 2>/dev/null || true        # Large Receive Offload (off for routing)

    # Scatter-gather
    ${pkgs.ethtool}/bin/ethtool -K ${iface} sg on 2>/dev/null || true

    # UDP fragmentation offload
    ${pkgs.ethtool}/bin/ethtool -K ${iface} ufo on 2>/dev/null || true

    # Receive hashing for multi-queue NICs
    ${pkgs.ethtool}/bin/ethtool -K ${iface} rxhash on 2>/dev/null || true
    ${pkgs.ethtool}/bin/ethtool -K ${iface} rxvlan on 2>/dev/null || true
    ${pkgs.ethtool}/bin/ethtool -K ${iface} txvlan on 2>/dev/null || true

    # NTUPLE filtering for flow steering
    ${pkgs.ethtool}/bin/ethtool -K ${iface} ntuple on 2>/dev/null || true

    # Receive flow steering
    ${pkgs.ethtool}/bin/ethtool -K ${iface} rx-flow-hash on 2>/dev/null || true

    # Hardware timestamps (useful for PTP)
    ${pkgs.ethtool}/bin/ethtool -K ${iface} tx-tcp-segmentation on 2>/dev/null || true
    ${pkgs.ethtool}/bin/ethtool -K ${iface} tx-tcp-ecn-segmentation on 2>/dev/null || true
    ${pkgs.ethtool}/bin/ethtool -K ${iface} tx-tcp6-segmentation on 2>/dev/null || true
    ${pkgs.ethtool}/bin/ethtool -K ${iface} tx-tcp-mangleid-segmentation on 2>/dev/null || true

    # Offload for tunneled packets
    ${pkgs.ethtool}/bin/ethtool -K ${iface} tx-gre-segmentation on 2>/dev/null || true
    ${pkgs.ethtool}/bin/ethtool -K ${iface} tx-gre-csum-segmentation on 2>/dev/null || true
    ${pkgs.ethtool}/bin/ethtool -K ${iface} tx-ipxip4-segmentation on 2>/dev/null || true
    ${pkgs.ethtool}/bin/ethtool -K ${iface} tx-ipxip6-segmentation on 2>/dev/null || true
    ${pkgs.ethtool}/bin/ethtool -K ${iface} tx-udp_tnl-segmentation on 2>/dev/null || true
    ${pkgs.ethtool}/bin/ethtool -K ${iface} tx-udp_tnl-csum-segmentation on 2>/dev/null || true

    # VXLAN and Geneve offloading (for overlay networks)
    ${pkgs.ethtool}/bin/ethtool -K ${iface} tx-vxlan-segmentation on 2>/dev/null || true
    ${pkgs.ethtool}/bin/ethtool -K ${iface} tx-geneve-segmentation on 2>/dev/null || true

    # Enable hardware LRO for non-routing interfaces (like WAN)
    if [ "${iface}" = "${interfaces.wan}" ]; then
      ${pkgs.ethtool}/bin/ethtool -K ${iface} lro on 2>/dev/null || true
    fi

    # Configure RSS (Receive Side Scaling) for multi-queue NICs
    # Check if the interface supports multiple queues
    QUEUES=$(${pkgs.ethtool}/bin/ethtool -l ${iface} 2>/dev/null | grep -A1 "Combined:" | tail -n1 | awk '{print $2}')
    if [ -n "$QUEUES" ] && [ "$QUEUES" -gt 1 ]; then
      echo "  Configuring RSS with $QUEUES queues..."
      ${pkgs.ethtool}/bin/ethtool -L ${iface} combined $QUEUES 2>/dev/null || true

      # Configure RSS hash
      ${pkgs.ethtool}/bin/ethtool -X ${iface} hfunc toeplitz 2>/dev/null || true
      ${pkgs.ethtool}/bin/ethtool -N ${iface} rx-flow-hash tcp4 sdfn 2>/dev/null || true
      ${pkgs.ethtool}/bin/ethtool -N ${iface} rx-flow-hash udp4 sdfn 2>/dev/null || true
      ${pkgs.ethtool}/bin/ethtool -N ${iface} rx-flow-hash tcp6 sdfn 2>/dev/null || true
      ${pkgs.ethtool}/bin/ethtool -N ${iface} rx-flow-hash udp6 sdfn 2>/dev/null || true
    fi

    # Configure interrupt coalescing for better latency/throughput balance
    ${pkgs.ethtool}/bin/ethtool -C ${iface} adaptive-rx on adaptive-tx on 2>/dev/null || true
    ${pkgs.ethtool}/bin/ethtool -C ${iface} rx-usecs 10 tx-usecs 10 2>/dev/null || true
    ${pkgs.ethtool}/bin/ethtool -C ${iface} rx-frames 64 tx-frames 64 2>/dev/null || true

    # Increase ring buffer sizes for better burst handling
    # Try to set to maximum supported values
    MAX_RX=$(${pkgs.ethtool}/bin/ethtool -g ${iface} 2>/dev/null | grep "RX:" | head -n1 | awk '{print $2}')
    MAX_TX=$(${pkgs.ethtool}/bin/ethtool -g ${iface} 2>/dev/null | grep "TX:" | head -n1 | awk '{print $2}')

    if [ -n "$MAX_RX" ] && [ "$MAX_RX" -gt 0 ]; then
      echo "  Setting RX ring buffer to $MAX_RX..."
      ${pkgs.ethtool}/bin/ethtool -G ${iface} rx $MAX_RX 2>/dev/null || true
    fi

    if [ -n "$MAX_TX" ] && [ "$MAX_TX" -gt 0 ]; then
      echo "  Setting TX ring buffer to $MAX_TX..."
      ${pkgs.ethtool}/bin/ethtool -G ${iface} tx $MAX_TX 2>/dev/null || true
    fi

    # Enable pause frames for flow control
    ${pkgs.ethtool}/bin/ethtool -A ${iface} rx on tx on 2>/dev/null || true

    # Set interface speed and duplex to maximum supported
    # This ensures we're not auto-negotiating to a lower speed
    ${pkgs.ethtool}/bin/ethtool -s ${iface} speed 2500 duplex full autoneg on 2>/dev/null || true

    echo "  Hardware offload configuration complete for ${iface}"
  '';
in {
  # System service to configure hardware offloading
  systemd.services.network-hardware-offload = {
    description = "Configure hardware offloading for network interfaces";
    wantedBy = ["network.target"];
    after = ["network-pre.target"];
    before = ["network.target"];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeScript "configure-offload" ''
        #!${pkgs.bash}/bin/bash
        set -e

        echo "Configuring hardware offloading for network interfaces..."

        # Configure WAN interface
        ${offloadScript interfaces.wan}

        # Configure LAN interfaces
        ${offloadScript interfaces.lan1}
        ${offloadScript interfaces.lan2}
        ${offloadScript interfaces.lan3}

        # Configure bridge interface (limited offloading)
        echo "Configuring bridge offloading..."
        ${pkgs.ethtool}/bin/ethtool -K br-lan tx-checksum-ip-generic on 2>/dev/null || true
        ${pkgs.ethtool}/bin/ethtool -K br-lan sg on 2>/dev/null || true

        # Display final status
        echo ""
        echo "Hardware offload status:"
        for iface in ${interfaces.wan} ${interfaces.lan1} ${interfaces.lan2} ${interfaces.lan3} br-lan; do
          if [ -e "/sys/class/net/$iface" ]; then
            echo ""
            echo "Interface: $iface"
            ${pkgs.ethtool}/bin/ethtool -k $iface 2>/dev/null | grep -E "tcp-segmentation-offload|generic-segmentation-offload|generic-receive-offload|large-receive-offload|rx-checksumming|tx-checksumming" | head -6 || true
          fi
        done

        echo ""
        echo "Hardware offloading configuration complete!"
      '';
    };
  };

  # Monitor offload effectiveness
  systemd.services.offload-monitor = {
    description = "Monitor hardware offload statistics";
    after = ["network-hardware-offload.service"];

    serviceConfig = {
      Type = "oneshot";
      ExecStart = pkgs.writeScript "monitor-offload" ''
        #!${pkgs.bash}/bin/bash

        # Export metrics for Prometheus node exporter
        mkdir -p /var/lib/prometheus/node-exporter

        for iface in ${interfaces.wan} ${interfaces.lan1} ${interfaces.lan2} ${interfaces.lan3}; do
          if [ -e "/sys/class/net/$iface" ]; then
            # Get offload status
            TSO=$(${pkgs.ethtool}/bin/ethtool -k $iface 2>/dev/null | grep "tcp-segmentation-offload:" | grep -c "on" || echo 0)
            GSO=$(${pkgs.ethtool}/bin/ethtool -k $iface 2>/dev/null | grep "generic-segmentation-offload:" | grep -c "on" || echo 0)
            GRO=$(${pkgs.ethtool}/bin/ethtool -k $iface 2>/dev/null | grep "generic-receive-offload:" | grep -c "on" || echo 0)

            # Write metrics
            cat >> /var/lib/prometheus/node-exporter/offload.prom <<EOF
        # HELP network_offload_tso TCP Segmentation Offload status (1=on, 0=off)
        # TYPE network_offload_tso gauge
        network_offload_tso{interface="$iface"} $TSO
        # HELP network_offload_gso Generic Segmentation Offload status (1=on, 0=off)
        # TYPE network_offload_gso gauge
        network_offload_gso{interface="$iface"} $GSO
        # HELP network_offload_gro Generic Receive Offload status (1=on, 0=off)
        # TYPE network_offload_gro gauge
        network_offload_gro{interface="$iface"} $GRO
        EOF
          fi
        done
      '';
    };
  };

  # Run monitor periodically
  systemd.timers.offload-monitor = {
    wantedBy = ["timers.target"];
    timerConfig = {
      OnBootSec = "5min";
      OnUnitActiveSec = "5min";
    };
  };

  # Ensure ethtool is available
  environment.systemPackages = [pkgs.ethtool];

  # Kernel modules for offloading support
  boot.kernelModules = [
    "tcp_offload"
    "udp_offload"
    "ipip"
    "gre"
    "vxlan"
  ];
}
