{
  config,
  lib,
  pkgs,
  ...
}: let
  netConfig = config.router.network;
  network = "${netConfig.prefix}.0/${toString netConfig.cidr}";
  routerIp = "${netConfig.prefix}.1";
in {
  # Prometheus for metrics collection
  services.prometheus = {
    enable = true;
    port = 9090;

    scrapeConfigs = [
      {
        job_name = "blocky";
        static_configs = [
          {
            targets = ["localhost:4000"];
          }
        ];
      }
      {
        job_name = "node";
        static_configs = [
          {
            targets = ["localhost:9100"];
          }
        ];
      }
    ];
  };

  # Node exporter for system metrics
  services.prometheus.exporters.node = {
    enable = true;
    port = 9100;
    enabledCollectors = [
      "systemd"
      "tcpstat"
      "netstat"
      "netdev"
      "diskstats"
      "filesystem"
      "meminfo"
      "cpu"
      "loadavg"
      "thermal_zone"
      "hwmon"
      "stat"
      "time"
      "uname"
      "vmstat"
      "netclass"
      "sockstat"
      "pressure"
    ];
    extraFlags = [
      "--collector.textfile.directory=/var/lib/prometheus-node-exporter-text-files"
    ];
  };

  # Custom script to track per-client traffic
  systemd.services.client-traffic-tracker = {
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
            ${pkgs.iproute2}/bin/ip neigh show | grep 'br-lan' | grep -E '${netConfig.prefix}\.[0-9]+' | ${pkgs.gawk}/bin/awk '{print $1}' | sort -u

            # Method 2: Active connections
            ${pkgs.conntrack-tools}/bin/conntrack -L 2>/dev/null | grep -oE '${netConfig.prefix}\.[0-9]+' | sort -u || true
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
  };

  # Textfile collector for client traffic metrics
  systemd.services.client-traffic-exporter = {
    description = "Export client traffic metrics for Prometheus";
    after = ["client-traffic-tracker.service" "prometheus-node-exporter.service"];
    wants = ["client-traffic-tracker.service"];
    wantedBy = ["multi-user.target"];
    serviceConfig = {
      Type = "simple";
      ExecStart = let
        script = pkgs.writeScript "export-client-traffic" ''
          #!${pkgs.bash}/bin/bash
          set -e

          # Function to get client name
          get_client_name() {
            local ip="$1"

            # Check the generated hosts file first
            if [ -f /var/lib/dnsmasq/dhcp-hosts ]; then
              local hostname=$(${pkgs.gawk}/bin/awk -v ip="$ip" '$1 == ip {print $2; exit}' /var/lib/dnsmasq/dhcp-hosts 2>/dev/null)
              if [ -n "$hostname" ]; then
                # Remove .lan suffix if present
                hostname=''${hostname%.lan}
                echo "$hostname"
                return
              fi
            fi

            # Fallback: check dnsmasq lease file directly
            if [ -f /var/lib/dnsmasq/dnsmasq.leases ]; then
              hostname=$(${pkgs.gawk}/bin/awk -v ip="$ip" '$3 == ip && $4 != "*" {print $4; exit}' /var/lib/dnsmasq/dnsmasq.leases 2>/dev/null)
              if [ -n "$hostname" ]; then
                echo "$hostname"
                return
              fi
            fi

            echo ""
          }

          mkdir -p /var/lib/prometheus-node-exporter-text-files

          while true; do
            {
              echo "# HELP client_traffic_bytes Total traffic per client"
              echo "# TYPE client_traffic_bytes counter"

              # Parse nftables counters
              ${pkgs.nftables}/bin/nft -j list chain inet filter CLIENT_TRAFFIC 2>/dev/null | \
              ${pkgs.jq}/bin/jq -r '
                .nftables[] |
                select(.rule != null) |
                .rule |
                select(.comment != null) |
                .comment as $comment |
                .expr[] |
                select(.counter != null) |
                "\($comment) " + (.counter.bytes | tostring)
              ' | while read comment bytes; do
                # Extract direction and IP from comment
                if [[ "$comment" =~ ^(tx|rx)_([0-9.]+)$ ]]; then
                  direction="''${BASH_REMATCH[1]}"
                  ip="''${BASH_REMATCH[2]}"

                  # Get client name
                  client_name=$(get_client_name "$ip")

                  # Output metric
                  if [ -n "$client_name" ]; then
                    echo "client_traffic_bytes{direction=\"$direction\",ip=\"$ip\",client=\"$client_name\"} $bytes"
                  else
                    echo "client_traffic_bytes{direction=\"$direction\",ip=\"$ip\",client=\"unknown\"} $bytes"
                  fi
                fi
              done
            } > /var/lib/prometheus-node-exporter-text-files/client_traffic.prom.tmp

            # Atomic move
            mv /var/lib/prometheus-node-exporter-text-files/client_traffic.prom.tmp \
               /var/lib/prometheus-node-exporter-text-files/client_traffic.prom

            sleep 10
          done
        '';
      in "${script}";
      Restart = "always";
      RestartSec = "10s";
    };
  };

  # UPnP metrics exporter
  systemd.services.upnp-metrics-exporter = {
    description = "Export UPnP metrics for Prometheus";
    after = ["miniupnpd.service" "prometheus-node-exporter.service"];
    wants = ["miniupnpd.service"];
    wantedBy = ["multi-user.target"];
    serviceConfig = {
      Type = "simple";
      ExecStart = let
        script = pkgs.writeScript "export-upnp-metrics" ''
          #!${pkgs.bash}/bin/bash

          mkdir -p /var/lib/prometheus-node-exporter-text-files
          mkdir -p /var/lib/miniupnpd

          # Function to get UPnP service status
          get_upnp_status() {
            if systemctl is-active miniupnpd >/dev/null 2>&1; then
              echo "1"
            else
              echo "0"
            fi
          }

          # Function to count active port mappings from lease file
          count_active_mappings() {
            if [ -f /var/lib/miniupnpd/upnp.leases ]; then
              wc -l < /var/lib/miniupnpd/upnp.leases 2>/dev/null || echo "0"
            else
              echo "0"
            fi
          }

          # Function to count firewall rules created by miniupnpd
          count_upnp_firewall_rules() {
            local forward_rules=0
            local nat_rules=0

            # Count rules in MINIUPNPD chains
            if ${pkgs.nftables}/bin/nft list chain inet filter MINIUPNPD >/dev/null 2>&1; then
              forward_rules=$(${pkgs.nftables}/bin/nft list chain inet filter MINIUPNPD 2>/dev/null | grep -c "tcp dport") || forward_rules=0
            fi

            if ${pkgs.nftables}/bin/nft list chain ip nat MINIUPNPD >/dev/null 2>&1; then
              nat_rules=$(${pkgs.nftables}/bin/nft list chain ip nat MINIUPNPD 2>/dev/null | grep -c "dnat to") || nat_rules=0
            fi

            # Ensure we always have values
            forward_rules=''${forward_rules:-0}
            nat_rules=''${nat_rules:-0}

            echo "$forward_rules $nat_rules"
          }

          # Function to check if UPnP HTTP interface is responsive
          check_upnp_http() {
            if ${pkgs.curl}/bin/curl -s --connect-timeout 2 --max-time 5 "http://localhost:2189/rootDesc.xml" >/dev/null 2>&1; then
              echo "1"
            else
              echo "0"
            fi
          }

          # Function to parse recent journal logs for UPnP activity
          get_upnp_log_metrics() {
            local log_since="5 minutes ago"
            local temp_file="/tmp/upnp_journal.log"

            # Get recent miniupnpd journal entries
            ${pkgs.systemd}/bin/journalctl -u miniupnpd --since="$log_since" --no-pager -o cat > "$temp_file" 2>/dev/null || true

            # Count different types of events
            local add_mapping=$(grep -c "addentry: UPnP" "$temp_file" 2>/dev/null) || add_mapping=0
            local del_mapping=$(grep -c "delentry: UPnP" "$temp_file" 2>/dev/null) || del_mapping=0
            local nat_mapping=$(grep -c "addentry: NAT-PMP" "$temp_file" 2>/dev/null) || nat_mapping=0
            local discovery=$(grep -c "SSDP M-SEARCH" "$temp_file" 2>/dev/null) || discovery=0
            local errors=$(grep -c -i "error\|fail\|deny" "$temp_file" 2>/dev/null) || errors=0

            rm -f "$temp_file"
            echo "$add_mapping $del_mapping $nat_mapping $discovery $errors"
          }

          while true; do
            {
              echo "# HELP upnp_service_status UPnP service status (1=running, 0=stopped)"
              echo "# TYPE upnp_service_status gauge"
              echo "upnp_service_status $(get_upnp_status)"
              echo ""

              echo "# HELP upnp_http_interface_available UPnP HTTP interface availability"
              echo "# TYPE upnp_http_interface_available gauge"
              echo "upnp_http_interface_available $(check_upnp_http)"
              echo ""

              echo "# HELP upnp_active_mappings Number of active UPnP port mappings"
              echo "# TYPE upnp_active_mappings gauge"
              echo "upnp_active_mappings $(count_active_mappings)"
              echo ""

              # Firewall rules metrics
              read forward_rules nat_rules <<< "$(count_upnp_firewall_rules)"
              echo "# HELP upnp_firewall_rules_total Number of firewall rules created by UPnP"
              echo "# TYPE upnp_firewall_rules_total gauge"
              echo "upnp_firewall_rules_total{type=\"forward\"} $forward_rules"
              echo "upnp_firewall_rules_total{type=\"nat\"} $nat_rules"
              echo ""

              # Log-based activity metrics (5-minute windows)
              read add_mapping del_mapping nat_mapping discovery errors <<< "$(get_upnp_log_metrics)"
              echo "# HELP upnp_activity_total UPnP activity from logs (5-minute window)"
              echo "# TYPE upnp_activity_total counter"
              echo "upnp_activity_total{type=\"add_mapping\"} $add_mapping"
              echo "upnp_activity_total{type=\"del_mapping\"} $del_mapping"
              echo "upnp_activity_total{type=\"nat_mapping\"} $nat_mapping"
              echo "upnp_activity_total{type=\"discovery\"} $discovery"
              echo "upnp_activity_total{type=\"errors\"} $errors"
              echo ""

              # Check if port 2189 is listening
              echo "# HELP upnp_port_listening UPnP port 2189 listening status"
              echo "# TYPE upnp_port_listening gauge"
              if ${pkgs.nettools}/bin/netstat -tln 2>/dev/null | grep -q ":2189 "; then
                echo "upnp_port_listening 1"
              else
                echo "upnp_port_listening 0"
              fi
              echo ""

              # Process metrics
              echo "# HELP upnp_process_memory_bytes miniupnpd process memory usage"
              echo "# TYPE upnp_process_memory_bytes gauge"
              memory_kb=$(ps -C miniupnpd -o rss= 2>/dev/null | head -1 | tr -d ' ' || echo "0")
              memory_bytes=$((memory_kb * 1024))
              echo "upnp_process_memory_bytes $memory_bytes"

            } > /var/lib/prometheus-node-exporter-text-files/upnp.prom.tmp

            # Atomic move
            mv /var/lib/prometheus-node-exporter-text-files/upnp.prom.tmp \
               /var/lib/prometheus-node-exporter-text-files/upnp.prom

            sleep 30
          done
        '';
      in "${script}";
      Restart = "always";
      User = "root"; # Needed for nftables and journalctl access
    };
  };

  # Create UPnP directory
  systemd.tmpfiles.rules = [
    "d /var/lib/prometheus-node-exporter-text-files 0755 nobody nogroup -"
    "d /var/lib/miniupnpd 0755 root root -"
  ];

  # Daily speed test service
  systemd.services.speedtest = {
    description = "Internet speed test";
    serviceConfig = {
      Type = "oneshot";
      User = "root";
      ExecStart = let
        script = pkgs.writeScript "speedtest-runner" ''
          #!${pkgs.bash}/bin/bash
          set -e

          echo "Running speed test..."

          # Run speedtest and capture results
          RESULT=$(${pkgs.speedtest-cli}/bin/speedtest --json 2>/dev/null || echo '{}')

          # Check if we got valid results
          if [ "$RESULT" = "{}" ]; then
            echo "Speed test failed, using fallback"
            DOWNLOAD=0
            UPLOAD=0
            PING=0
            TIMESTAMP=$(date +%s)
          else
            # Parse JSON results
            DOWNLOAD=$(echo "$RESULT" | ${pkgs.jq}/bin/jq -r '.download // 0')
            UPLOAD=$(echo "$RESULT" | ${pkgs.jq}/bin/jq -r '.upload // 0')
            PING=$(echo "$RESULT" | ${pkgs.jq}/bin/jq -r '.ping // 0')
            TIMESTAMP=$(echo "$RESULT" | ${pkgs.jq}/bin/jq -r '.timestamp // 0')

            # Convert timestamp to Unix epoch if it's in ISO format
            if [[ "$TIMESTAMP" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T ]]; then
              TIMESTAMP=$(date -d "$TIMESTAMP" +%s)
            fi

            # Ensure we have numeric values
            DOWNLOAD=$(echo "$DOWNLOAD" | ${pkgs.gawk}/bin/awk '{print ($1+0)}')
            UPLOAD=$(echo "$UPLOAD" | ${pkgs.gawk}/bin/awk '{print ($1+0)}')
            PING=$(echo "$PING" | ${pkgs.gawk}/bin/awk '{print ($1+0)}')

            echo "Parsed values: Download=$DOWNLOAD bits/s, Upload=$UPLOAD bits/s, Ping=$PING ms"
          fi

          # Convert bits to Mbps (speedtest-cli returns bits per second)
          # Handle empty values by defaulting to 0
          if [ -z "$DOWNLOAD" ] || [ "$DOWNLOAD" = "0" ]; then
            DOWNLOAD_MBPS=0
          else
            DOWNLOAD_MBPS=$(echo "$DOWNLOAD" | ${pkgs.gawk}/bin/awk '{printf "%.2f", $1/1000000}')
          fi

          if [ -z "$UPLOAD" ] || [ "$UPLOAD" = "0" ]; then
            UPLOAD_MBPS=0
          else
            UPLOAD_MBPS=$(echo "$UPLOAD" | ${pkgs.gawk}/bin/awk '{printf "%.2f", $1/1000000}')
          fi

          # Write metrics to prometheus textfile
          {
            echo "# HELP speedtest_download_mbps Download speed in Mbps"
            echo "# TYPE speedtest_download_mbps gauge"
            echo "speedtest_download_mbps $DOWNLOAD_MBPS"
            echo ""
            echo "# HELP speedtest_upload_mbps Upload speed in Mbps"
            echo "# TYPE speedtest_upload_mbps gauge"
            echo "speedtest_upload_mbps $UPLOAD_MBPS"
            echo ""
            echo "# HELP speedtest_ping_ms Ping latency in milliseconds"
            echo "# TYPE speedtest_ping_ms gauge"
            echo "speedtest_ping_ms $PING"
            echo ""
            echo "# HELP speedtest_timestamp_seconds Timestamp of last speed test"
            echo "# TYPE speedtest_timestamp_seconds gauge"
            echo "speedtest_timestamp_seconds $TIMESTAMP"
            echo ""
            echo "# HELP speedtest_success Whether the speed test was successful"
            echo "# TYPE speedtest_success gauge"
            if [ "$RESULT" != "{}" ]; then
              echo "speedtest_success 1"
            else
              echo "speedtest_success 0"
            fi
          } > /var/lib/prometheus-node-exporter-text-files/speedtest.prom.tmp

          # Atomic move
          mv /var/lib/prometheus-node-exporter-text-files/speedtest.prom.tmp \
             /var/lib/prometheus-node-exporter-text-files/speedtest.prom

          echo "Speed test completed: Download=$DOWNLOAD_MBPS Mbps, Upload=$UPLOAD_MBPS Mbps, Ping=$PING ms"
        '';
      in "${script}";
    };
  };

  # Timer for daily speed test
  systemd.timers.speedtest = {
    description = "Daily speed test timer";
    wantedBy = ["timers.target"];
    timerConfig = {
      OnCalendar = "daily";
      Persistent = true;
      RandomizedDelaySec = "30m"; # Random delay up to 30 minutes
    };
  };

  # Grafana for visualization
  services.grafana = {
    enable = true;
    settings = {
      server = {
        http_addr = "0.0.0.0";
        http_port = 3000;
      };
      security = {
        admin_user = "admin";
        admin_password = "admin";
      };
    };

    provision = {
      enable = true;

      datasources.settings.datasources = [
        {
          name = "Prometheus";
          type = "prometheus";
          url = "http://localhost:9090/prometheus";
          isDefault = true;
        }
      ];

      dashboards.settings.providers = [
        {
          name = "Router Dashboards";
          folder = "Router";
          type = "file";
          options.path = pkgs.writeTextDir "router-metrics.json" (builtins.toJSON (import ../dashboards {inherit lib pkgs;}));
        }
      ];
    };
  };
}
