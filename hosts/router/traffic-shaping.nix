{
  config,
  lib,
  pkgs,
  ...
}: let
  # Get interface names from configuration
  interfaces = config.router.interfaces;

  # Traffic shaping configuration options
  shapingConfig = config.router.trafficShaping;

  # Create tc script for interface shaping
  createShapingScript = iface: config: ''
    echo "Configuring traffic shaping on ${iface}..."

    # Delete any existing qdisc
    ${pkgs.iproute2}/bin/tc qdisc del dev ${iface} root 2>/dev/null || true
    ${pkgs.iproute2}/bin/tc qdisc del dev ${iface} ingress 2>/dev/null || true

    # Apply CAKE qdisc for egress shaping
    ${pkgs.iproute2}/bin/tc qdisc add dev ${iface} root cake \
      bandwidth ${toString config.bandwidth}Mbit \
      ${config.overhead} \
      ${
      if config.nat
      then "nat"
      else "nonat"
    } \
      ${
      if config.wash
      then "wash"
      else "nowash"
    } \
      ${
      if config.ackFilter
      then "ack-filter"
      else "no-ack-filter"
    } \
      ${config.flowMode} \
      ${config.rttMode}

    # Apply ingress shaping if configured
    ${lib.optionalString (config.ingressBandwidth != null) ''
      # Create IFB device for ingress shaping
      ${pkgs.kmod}/bin/modprobe ifb numifbs=1 || true

      # Wait a bit for the module to load
      sleep 0.5

      # Check if ifb0 exists, create if not
      if ! ${pkgs.iproute2}/bin/ip link show ifb0 2>/dev/null; then
        echo "IFB module not loaded properly, skipping ingress shaping"
      else
        ${pkgs.iproute2}/bin/ip link set dev ifb0 up

        # Delete any existing qdisc on ifb0
        ${pkgs.iproute2}/bin/tc qdisc del dev ifb0 root 2>/dev/null || true

        # Redirect ingress traffic to IFB
        ${pkgs.iproute2}/bin/tc qdisc add dev ${iface} handle ffff: ingress
        ${pkgs.iproute2}/bin/tc filter add dev ${iface} parent ffff: protocol all u32 match u32 0 0 action mirred egress redirect dev ifb0

        # Apply CAKE to IFB for ingress shaping
        ${pkgs.iproute2}/bin/tc qdisc add dev ifb0 root cake \
          bandwidth ${toString config.ingressBandwidth}Mbit \
          ${config.overhead} \
          ${
        if config.nat
        then "nat"
        else "nonat"
      } \
          ${
        if config.wash
        then "wash"
        else "nowash"
      } \
          ${config.flowMode} \
          ${config.rttMode} \
          ingress
      fi
    ''}

    echo "Traffic shaping configured on ${iface}"
  '';

  # Create advanced classification rules
  createClassificationRules = ''
    # DSCP marking for common traffic types

    # Interactive SSH
    tcp sport 22 ip dscp set cs7
    tcp dport 22 ip dscp set cs7

    # DNS
    udp sport 53 ip dscp set cs6
    udp dport 53 ip dscp set cs6
    tcp sport 53 ip dscp set cs6
    tcp dport 53 ip dscp set cs6

    # VoIP (common ports)
    udp sport 5060-5061 ip dscp set ef
    udp dport 5060-5061 ip dscp set ef
    udp sport 10000-20000 ip dscp set ef
    udp dport 10000-20000 ip dscp set ef

    # Video conferencing
    udp dport 3478-3481 ip dscp set af41
    tcp dport 3478-3481 ip dscp set af41

    # Gaming (common ports)
    udp dport 27000-27050 ip dscp set cs4
    tcp dport 27000-27050 ip dscp set cs4

    # Bulk traffic (backup, large downloads)
    tcp sport 873 ip dscp set cs1  # rsync
    tcp dport 873 ip dscp set cs1

    # BitTorrent
    tcp sport 6881-6889 ip dscp set cs1
    tcp dport 6881-6889 ip dscp set cs1
    udp sport 6881-6889 ip dscp set cs1
    udp dport 6881-6889 ip dscp set cs1
  '';

  # QoS monitoring script
  qosMonitoringScript = pkgs.writeScript "qos-monitor" ''
    #!${pkgs.bash}/bin/bash

    mkdir -p /var/lib/prometheus-node-exporter-text-files

    # Define interfaces to monitor
    INTERFACES="${interfaces.wan} ifb0"
    ${lib.optionalString shapingConfig.lanShaping.enable ''
      INTERFACES="$INTERFACES br-lan"
    ''}

    while true; do
      {
        echo "# HELP cake_stats CAKE qdisc statistics"
        echo "# TYPE cake_stats gauge"

        # Collect CAKE statistics
        for iface in $INTERFACES; do
          # Skip if device doesn't exist
          if ! ${pkgs.iproute2}/bin/ip link show $iface &>/dev/null; then
            continue
          fi

          if ${pkgs.iproute2}/bin/tc qdisc show dev $iface 2>/dev/null | ${pkgs.gnugrep}/bin/grep -q cake; then
            # Parse CAKE statistics
            stats=$(${pkgs.iproute2}/bin/tc -s qdisc show dev $iface | ${pkgs.gnugrep}/bin/grep -A20 "qdisc cake")

            # Extract key metrics
            if [ -n "$stats" ]; then
              # Bytes and packets
              bytes=$(echo "$stats" | ${pkgs.gnugrep}/bin/grep -oP "Sent \K[0-9]+" | ${pkgs.coreutils}/bin/head -1 || echo 0)
              packets=$(echo "$stats" | ${pkgs.gnugrep}/bin/grep -oP "Sent [0-9]+ bytes \K[0-9]+" | ${pkgs.coreutils}/bin/head -1 || echo 0)

              # Drops and marks
              drops=$(echo "$stats" | ${pkgs.gnugrep}/bin/grep -oP "dropped \K[0-9]+" | ${pkgs.coreutils}/bin/head -1 || echo 0)
              overlimits=$(echo "$stats" | ${pkgs.gnugrep}/bin/grep -oP "overlimits \K[0-9]+" | ${pkgs.coreutils}/bin/head -1 || echo 0)

              # Latency stats from CAKE
              avg_delay=$(${pkgs.iproute2}/bin/tc -s qdisc show dev $iface | ${pkgs.gnugrep}/bin/grep -A50 "qdisc cake" | ${pkgs.gnugrep}/bin/grep -oP "delay\s+\K[0-9.]+us" | ${pkgs.coreutils}/bin/head -1 | ${pkgs.gnused}/bin/sed 's/us//' || echo 0)

              echo "cake_stats{device=\"$iface\",metric=\"bytes\"} $bytes"
              echo "cake_stats{device=\"$iface\",metric=\"packets\"} $packets"
              echo "cake_stats{device=\"$iface\",metric=\"drops\"} $drops"
              echo "cake_stats{device=\"$iface\",metric=\"overlimits\"} $overlimits"
              echo "cake_stats{device=\"$iface\",metric=\"avg_delay_us\"} $avg_delay"

              # Per-tin statistics if available
              tin_stats=$(${pkgs.iproute2}/bin/tc -s class show dev $iface 2>/dev/null)
              if [ -n "$tin_stats" ]; then
                tin_num=0
                echo "$tin_stats" | while read -r line; do
                  if echo "$line" | ${pkgs.gnugrep}/bin/grep -q "class cake"; then
                    tin_bytes=$(echo "$line" | ${pkgs.gnugrep}/bin/grep -oP "Sent \K[0-9]+" || echo 0)
                    tin_packets=$(echo "$line" | ${pkgs.gnugrep}/bin/grep -oP "Sent [0-9]+ bytes \K[0-9]+" || echo 0)
                    echo "cake_tin_stats{device=\"$iface\",tin=\"$tin_num\",metric=\"bytes\"} $tin_bytes"
                    echo "cake_tin_stats{device=\"$iface\",tin=\"$tin_num\",metric=\"packets\"} $tin_packets"
                    ((tin_num++))
                  fi
                done
              fi
            fi
          fi
        done

        # Collect connection tracking stats for QoS
        echo "# HELP conntrack_by_dscp Connection count by DSCP marking"
        echo "# TYPE conntrack_by_dscp gauge"

        # Count connections by DSCP value
        ${pkgs.conntrack-tools}/bin/conntrack -L 2>/dev/null | \
        ${pkgs.gawk}/bin/awk '/^(tcp|udp)/ {
          dscp = 0
          if (match($0, /mark=([0-9]+)/, m)) {
            dscp = int(m[1] / 4) % 64
          }
          count[dscp]++
        }
        END {
          for (d in count) {
            print "conntrack_by_dscp{dscp=\"" d "\"} " count[d]
          }
        }'

      } > /var/lib/prometheus-node-exporter-text-files/qos_stats.prom.tmp

      # Atomic move
      mv /var/lib/prometheus-node-exporter-text-files/qos_stats.prom.tmp \
         /var/lib/prometheus-node-exporter-text-files/qos_stats.prom

      sleep 10
    done
  '';
in {
  options.router.trafficShaping = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable advanced traffic shaping with CAKE qdisc";
    };

    wanShaping = {
      bandwidth = lib.mkOption {
        type = lib.types.int;
        default = 100;
        description = "WAN upload bandwidth in Mbit/s";
      };

      ingressBandwidth = lib.mkOption {
        type = lib.types.nullOr lib.types.int;
        default = null;
        description = "WAN download bandwidth in Mbit/s (null to disable ingress shaping)";
      };

      overhead = lib.mkOption {
        type = lib.types.str;
        default = "ethernet";
        description = "Link layer overhead preset (docsis, ethernet, conservative, raw)";
      };

      nat = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Enable NAT mode for better flow tracking";
      };

      wash = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Clear DSCP marks on egress";
      };

      ackFilter = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Enable ACK filter to improve upload when downloading";
      };

      flowMode = lib.mkOption {
        type = lib.types.str;
        default = "triple-isolate";
        description = "Flow isolation mode (flowblind, flows, dual-srchost, dual-dsthost, triple-isolate)";
      };

      rttMode = lib.mkOption {
        type = lib.types.str;
        default = "datacentre";
        description = "RTT mode for AQM (datacentre, lan, metro, regional, internet, oceanic, satellite)";
      };
    };

    lanShaping = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Enable traffic shaping on LAN interface";
      };

      bandwidth = lib.mkOption {
        type = lib.types.int;
        default = 1000;
        description = "LAN bandwidth in Mbit/s";
      };

      ingressBandwidth = lib.mkOption {
        type = lib.types.nullOr lib.types.int;
        default = null;
        description = "LAN ingress bandwidth in Mbit/s";
      };

      overhead = lib.mkOption {
        type = lib.types.str;
        default = "ethernet";
        description = "Link layer overhead preset";
      };

      nat = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Enable NAT mode";
      };

      wash = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Clear DSCP marks";
      };

      ackFilter = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Enable ACK filter";
      };

      flowMode = lib.mkOption {
        type = lib.types.str;
        default = "flows";
        description = "Flow isolation mode";
      };

      rttMode = lib.mkOption {
        type = lib.types.str;
        default = "lan";
        description = "RTT mode for AQM";
      };
    };

    classification = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Enable traffic classification and DSCP marking";
      };

      customRules = lib.mkOption {
        type = lib.types.lines;
        default = "";
        description = "Custom nftables rules for traffic classification";
      };
    };

    monitoring = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Enable QoS monitoring metrics for Prometheus";
      };
    };
  };

  config = lib.mkIf shapingConfig.enable {
    # Ensure required kernel modules are loaded
    boot.kernelModules = ["sch_cake" "act_mirred" "cls_u32" "ifb"];

    # Ensure IFB interfaces are created at boot
    boot.kernelParams = ["ifb.numifbs=1"];

    # Add mangle table to nftables for DSCP marking
    networking.nftables.ruleset = lib.mkAfter ''
      table inet mangle {
        chain PREROUTING {
          type filter hook prerouting priority -150;
        }

        chain POSTROUTING {
          type filter hook postrouting priority -150;

          ${lib.optionalString shapingConfig.classification.enable ''
        # Apply default classification rules
        ${createClassificationRules}

        # Apply custom classification rules
        ${shapingConfig.classification.customRules}
      ''}
        }
      }
    '';

    # Create systemd service for traffic shaping
    systemd.services.traffic-shaping = {
      description = "Configure advanced traffic shaping with CAKE";
      after = ["network-online.target" "nftables.service"];
      wants = ["network-online.target"];
      wantedBy = ["multi-user.target"];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = let
          script = pkgs.writeScript "setup-traffic-shaping" ''
            #!${pkgs.bash}/bin/bash
            set -e

            echo "Setting up traffic shaping..."

            # Apply WAN shaping
            ${createShapingScript interfaces.wan shapingConfig.wanShaping}

            # Apply LAN shaping if enabled
            ${lib.optionalString shapingConfig.lanShaping.enable
              (createShapingScript "br-lan" shapingConfig.lanShaping)}

            echo "Traffic shaping setup complete"
          '';
        in "${script}";

        ExecStop = pkgs.writeScript "stop-traffic-shaping" ''
          #!${pkgs.bash}/bin/bash

          echo "Removing traffic shaping..."

          # Remove shaping from all interfaces
          for iface in ${interfaces.wan} br-lan ifb0; do
            ${pkgs.iproute2}/bin/tc qdisc del dev $iface root 2>/dev/null || true
            ${pkgs.iproute2}/bin/tc qdisc del dev $iface ingress 2>/dev/null || true
          done

          echo "Traffic shaping removed"
        '';
      };
    };

    # QoS monitoring service
    systemd.services.qos-monitoring = lib.mkIf shapingConfig.monitoring.enable {
      description = "Monitor QoS statistics for Prometheus";
      after = ["traffic-shaping.service" "prometheus-node-exporter.service"];
      wants = ["traffic-shaping.service"];
      wantedBy = ["multi-user.target"];

      serviceConfig = {
        Type = "simple";
        ExecStart = qosMonitoringScript;
        Restart = "always";
        RestartSec = "10s";
        User = "root"; # Needed for tc commands
      };
    };

    # Add tc package to system
    environment.systemPackages = with pkgs; [iproute2];
  };
}
