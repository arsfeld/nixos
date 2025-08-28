{
  config,
  lib,
  pkgs,
  ...
}:
with lib; let
  cfg = config.services.network-metrics-exporter;
in {
  options.services.network-metrics-exporter = {
    enable = mkEnableOption "network metrics exporter for per-client bandwidth monitoring";

    port = mkOption {
      type = types.port;
      default = 9101;
      description = "Port on which the exporter will listen";
    };

    updateInterval = mkOption {
      type = types.int;
      default = 2;
      description = "Interval in seconds between metric updates";
    };

    package = mkOption {
      type = types.package;
      default = pkgs.network-metrics-exporter;
      defaultText = literalExpression "pkgs.network-metrics-exporter";
      description = "The network-metrics-exporter package to use";
    };

    openFirewall = mkOption {
      type = types.bool;
      default = false;
      description = "Whether to open the firewall for the exporter port";
    };

    enableNftablesIntegration = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Enable automatic setup of nftables rules for traffic accounting.
        This creates a CLIENT_TRAFFIC chain and dynamically adds rules for each client.
        Disable this if you want to manage traffic accounting rules manually.
      '';
    };

    networkPrefix = mkOption {
      type = types.str;
      default = "192.168.10";
      example = "192.168.1";
      description = "Network prefix to monitor for client traffic";
    };

    trafficInterface = mkOption {
      type = types.str;
      default = "br-lan";
      example = "eth0";
      description = "Network interface to monitor for client discovery";
    };

    staticClients = mkOption {
      type = types.attrsOf (types.submodule {
        options = {
          ip = mkOption {
            type = types.str;
            description = "IP address of the client";
          };
          mac = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = "MAC address of the client";
          };
          hostname = mkOption {
            type = types.str;
            description = "Hostname of the client";
          };
          deviceType = mkOption {
            type = types.str;
            default = "unknown";
            description = "Type of device (computer, phone, iot, etc.)";
          };
        };
      });
      default = {};
      description = "Static client definitions with known device types";
    };
  };

  config = mkIf cfg.enable {
    # Create state directory
    systemd.tmpfiles.rules = [
      "d /var/lib/network-metrics-exporter 0755 root root -"
    ];

    # Create static clients file
    environment.etc."network-metrics-exporter/static-clients.json" = {
      text = builtins.toJSON cfg.staticClients;
      mode = "0644";
    };

    # Also write to the state directory for the service
    system.activationScripts.networkMetricsExporterStaticClients = ''
      mkdir -p /var/lib/network-metrics-exporter
      cat ${pkgs.writeText "static-clients.json" (builtins.toJSON cfg.staticClients)} > /var/lib/network-metrics-exporter/static-clients.json
    '';

    # Open firewall if requested
    networking.firewall.allowedTCPPorts = mkIf cfg.openFirewall [cfg.port];

    # Client traffic tracker service (optional)
    systemd.services.client-traffic-tracker = mkIf cfg.enableNftablesIntegration {
      description = "Track per-client network traffic";
      after = ["network-online.target" "nftables.service"];
      wants = ["network-online.target"];
      wantedBy = ["multi-user.target"];

      serviceConfig = {
        Type = "simple";
        Restart = "always";
        RestartSec = "30s";
        ExecStart = let
          script = pkgs.writeScript "setup-client-tracking" ''
            #!${pkgs.bash}/bin/bash
            set -e

            echo "Starting client traffic tracker..."

            # Ensure CLIENT_TRAFFIC chain exists
            if ! ${pkgs.nftables}/bin/nft list chain inet filter CLIENT_TRAFFIC 2>/dev/null; then
              echo "Creating CLIENT_TRAFFIC chain..."
              ${pkgs.nftables}/bin/nft add chain inet filter CLIENT_TRAFFIC
              ${pkgs.nftables}/bin/nft add rule inet filter forward jump CLIENT_TRAFFIC
            fi

            # Function to add rules for a client
            add_client_rules() {
              local client_ip="$1"
              echo "Adding traffic accounting for $client_ip"

              # Add TX rule (client sending data)
              if ! ${pkgs.nftables}/bin/nft list chain inet filter CLIENT_TRAFFIC | grep -q "tx_$client_ip"; then
                ${pkgs.nftables}/bin/nft add rule inet filter CLIENT_TRAFFIC ip saddr $client_ip counter comment "\"tx_$client_ip\"" || true
              fi

              # Add RX rule (client receiving data)
              if ! ${pkgs.nftables}/bin/nft list chain inet filter CLIENT_TRAFFIC | grep -q "rx_$client_ip"; then
                ${pkgs.nftables}/bin/nft add rule inet filter CLIENT_TRAFFIC ip daddr $client_ip counter comment "\"rx_$client_ip\"" || true
              fi
            }

            # Function to discover clients
            discover_clients() {
              # Method 1: ARP table
              ${pkgs.iproute2}/bin/ip neigh show | grep '${cfg.trafficInterface}' | grep -E '${cfg.networkPrefix}\.[0-9]+' | ${pkgs.gawk}/bin/awk '{print $1}' | sort -u

              # Method 2: Active connections
              ${pkgs.conntrack-tools}/bin/conntrack -L 2>/dev/null | grep -oE '${cfg.networkPrefix}\.[0-9]+' | sort -u || true
            }

            # Initial setup
            sleep 5

            # Continuous monitoring loop
            while true; do
              # Discover all active clients
              discover_clients | while read client_ip; do
                if [ -n "$client_ip" ]; then
                  add_client_rules "$client_ip"
                fi
              done

              # Wait before next discovery
              sleep 60
            done
          '';
        in "${script}";
      };

      path = with pkgs; [
        nftables
        conntrack-tools
        iproute2
        gawk
      ];
    };

    # Main exporter service
    systemd.services.network-metrics-exporter = {
      description = "Network Metrics Exporter";
      wantedBy = ["multi-user.target"];
      after = ["network.target"] ++ (optional cfg.enableNftablesIntegration "client-traffic-tracker.service");
      wants = optional cfg.enableNftablesIntegration "client-traffic-tracker.service";

      serviceConfig = {
        Type = "simple";
        ExecStart = "${cfg.package}/bin/network-metrics-exporter";
        Restart = "always";
        RestartSec = "10s";

        # Security hardening
        DynamicUser = false; # Need root for nftables access
        User = "root";
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ReadOnlyPaths = "/";
        ReadWritePaths = ["/var/lib/network-metrics-exporter"];
        StateDirectory = "network-metrics-exporter";

        # Required capabilities for network operations
        AmbientCapabilities = ["CAP_NET_ADMIN" "CAP_NET_RAW"];
        NoNewPrivileges = true;
      };

      environment = {
        METRICS_PORT = toString cfg.port;
        UPDATE_INTERVAL = toString cfg.updateInterval;
        WAN_INTERFACE = config.router.interfaces.wan or "";
        STATIC_CLIENTS_FILE = "/var/lib/network-metrics-exporter/static-clients.json";
        TRAFFIC_INTERFACE = cfg.trafficInterface;
        NETWORK_PREFIX = cfg.networkPrefix;
        DEBUG_TIMING = "true"; # Enable timing logs to debug performance
      };

      path = with pkgs; [
        nftables
        conntrack-tools
        iproute2
        arp-scan
        samba # for nmblookup (NetBIOS name discovery)
      ];
    };
  };
}
