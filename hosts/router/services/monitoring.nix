{
  config,
  lib,
  pkgs,
  self ? null,
  ...
}: let
  netConfig = config.router.network;
  network = "${netConfig.prefix}.0/${toString netConfig.cidr}";
  routerIp = "${netConfig.prefix}.1";
in {
  imports = if self != null then [
    "${self}/packages/network-metrics-exporter/module.nix"
  ] else [
    ../../../packages/network-metrics-exporter/module.nix
  ];

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
      {
        job_name = "network-metrics";
        static_configs = [
          {
            targets = ["localhost:9101"];
          }
        ];
      }
      {
        job_name = "natpmp";
        static_configs = [
          {
            targets = ["localhost:9333"];
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

  # Network metrics exporter configuration
  services.network-metrics-exporter = {
    enable = true;
    port = 9101;
    updateInterval = 2;
    openFirewall = false; # Firewall managed separately
    enableNftablesIntegration = true;
    networkPrefix = netConfig.prefix;
    trafficInterface = "br-lan";
  };

  # UPnP metrics exporter - disabled since we're using natpmp-server
  systemd.services.upnp-metrics-exporter = {
    enable = false;
    description = "Export UPnP metrics for Prometheus";
    after = ["miniupnpd.service" "prometheus-node-exporter.service"];
    wants = ["miniupnpd.service"];
    wantedBy = [];
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

          # Function to get port mapping count from iptables
          get_port_mapping_count() {
            # Count MINIUPNPD rules in NAT table (both TCP and UDP)
            ${pkgs.nftables}/bin/nft list chain ip nat MINIUPNPD 2>/dev/null | grep -c "dnat to" || echo "0"
          }

          # Function to get clients with active mappings
          get_active_clients() {
            # Extract unique client IPs from MINIUPNPD chain
            ${pkgs.nftables}/bin/nft list chain ip nat MINIUPNPD 2>/dev/null | \
              grep -oE "dnat to ${netConfig.prefix}\.[0-9]+" | \
              cut -d' ' -f3 | sort -u | wc -l || echo "0"
          }

          # Main loop
          while true; do
            {
              echo "# HELP upnp_status UPnP service status (1=active, 0=inactive)"
              echo "# TYPE upnp_status gauge"
              echo "upnp_status $(get_upnp_status)"

              echo "# HELP upnp_port_mappings_total Total number of active UPnP port mappings"
              echo "# TYPE upnp_port_mappings_total gauge"
              echo "upnp_port_mappings_total $(get_port_mapping_count)"

              echo "# HELP upnp_active_clients Number of clients with active UPnP mappings"
              echo "# TYPE upnp_active_clients gauge"
              echo "upnp_active_clients $(get_active_clients)"

              # If miniupnpd is running and we can access its lease file
              if [ -f /var/lib/miniupnpd/upnp.leases ]; then
                echo "# HELP upnp_mapping_info Information about active UPnP mappings"
                echo "# TYPE upnp_mapping_info gauge"

                # Parse the lease file
                # Format: protocol:external_port:internal_ip:internal_port:timestamp:description:enabled:internal_client:duration
                while IFS=: read -r proto ext_port int_ip int_port timestamp desc enabled client duration; do
                  if [ -n "$proto" ] && [ "$enabled" = "1" ]; then
                    # Escape description for Prometheus labels
                    desc_escaped=$(echo "$desc" | sed 's/"/\\"/g' | sed 's/\\/\\\\/g')
                    client_escaped=$(echo "$client" | sed 's/"/\\"/g' | sed 's/\\/\\\\/g')

                    echo "upnp_mapping_info{protocol=\"$proto\",external_port=\"$ext_port\",internal_ip=\"$int_ip\",internal_port=\"$int_port\",description=\"$desc_escaped\",client=\"$client_escaped\"} 1"
                  fi
                done < /var/lib/miniupnpd/upnp.leases 2>/dev/null || true
              fi

            } > /var/lib/prometheus-node-exporter-text-files/upnp.prom.tmp

            # Atomic move to avoid partial reads
            mv /var/lib/prometheus-node-exporter-text-files/upnp.prom.tmp \
               /var/lib/prometheus-node-exporter-text-files/upnp.prom

            sleep 10
          done
        '';
      in "${script}";
      Restart = "always";
      RestartSec = "10s";
    };
  };

  # Speed test metrics
  systemd.services.speedtest-exporter = {
    description = "Run periodic speed tests and export metrics";
    after = ["network-online.target" "prometheus-node-exporter.service"];
    wants = ["network-online.target"];
    wantedBy = ["multi-user.target"];
    serviceConfig = {
      Type = "simple";
      ExecStart = let
        speedtest-cli = pkgs.python3Packages.speedtest-cli;
        script = pkgs.writeScript "speedtest-exporter" ''
          #!${pkgs.bash}/bin/bash

          mkdir -p /var/lib/prometheus-node-exporter-text-files

          # Function to run speed test and format output
          run_speedtest() {
            echo "Running speed test..."

            # Run speedtest and capture JSON output
            result=$(${speedtest-cli}/bin/speedtest --json 2>/dev/null || echo '{"error": "speedtest failed"}')

            if echo "$result" | grep -q '"error"'; then
              echo "Speed test failed"
              return 1
            fi

            # Extract metrics from JSON
            download=$(echo "$result" | ${pkgs.jq}/bin/jq -r '.download // 0')
            upload=$(echo "$result" | ${pkgs.jq}/bin/jq -r '.upload // 0')
            ping=$(echo "$result" | ${pkgs.jq}/bin/jq -r '.ping // 0')
            server_name=$(echo "$result" | ${pkgs.jq}/bin/jq -r '.server.name // "unknown"' | sed 's/"/\\"/g')
            server_sponsor=$(echo "$result" | ${pkgs.jq}/bin/jq -r '.server.sponsor // "unknown"' | sed 's/"/\\"/g')

            {
              echo "# HELP speedtest_download_bits_per_second Download speed in bits per second"
              echo "# TYPE speedtest_download_bits_per_second gauge"
              echo "speedtest_download_bits_per_second $download"

              echo "# HELP speedtest_upload_bits_per_second Upload speed in bits per second"
              echo "# TYPE speedtest_upload_bits_per_second gauge"
              echo "speedtest_upload_bits_per_second $upload"

              echo "# HELP speedtest_ping_milliseconds Ping latency in milliseconds"
              echo "# TYPE speedtest_ping_milliseconds gauge"
              echo "speedtest_ping_milliseconds $ping"

              echo "# HELP speedtest_server_info Information about the speedtest server used"
              echo "# TYPE speedtest_server_info gauge"
              echo "speedtest_server_info{name=\"$server_name\",sponsor=\"$server_sponsor\"} 1"

              echo "# HELP speedtest_last_run_timestamp Unix timestamp of last successful speedtest"
              echo "# TYPE speedtest_last_run_timestamp gauge"
              echo "speedtest_last_run_timestamp $(date +%s)"
            } > /var/lib/prometheus-node-exporter-text-files/speedtest.prom.tmp

            # Atomic move
            mv /var/lib/prometheus-node-exporter-text-files/speedtest.prom.tmp \
               /var/lib/prometheus-node-exporter-text-files/speedtest.prom

            echo "Speed test completed successfully"
            return 0
          }

          # Initialize with empty metrics
          {
            echo "# HELP speedtest_download_bits_per_second Download speed in bits per second"
            echo "# TYPE speedtest_download_bits_per_second gauge"
            echo "speedtest_download_bits_per_second 0"

            echo "# HELP speedtest_upload_bits_per_second Upload speed in bits per second"
            echo "# TYPE speedtest_upload_bits_per_second gauge"
            echo "speedtest_upload_bits_per_second 0"

            echo "# HELP speedtest_ping_milliseconds Ping latency in milliseconds"
            echo "# TYPE speedtest_ping_milliseconds gauge"
            echo "speedtest_ping_milliseconds 0"

            echo "# HELP speedtest_last_run_timestamp Unix timestamp of last successful speedtest"
            echo "# TYPE speedtest_last_run_timestamp gauge"
            echo "speedtest_last_run_timestamp 0"
          } > /var/lib/prometheus-node-exporter-text-files/speedtest.prom

          # Run initial test after a short delay
          sleep 60
          run_speedtest

          # Main loop - run speed test every 4 hours
          while true; do
            sleep 14400  # 4 hours
            run_speedtest
          done
        '';
      in "${script}";
      Restart = "always";
      RestartSec = "60s";
    };
  };

  # Alerting configuration using Prometheus Alertmanager
  services.prometheus.alertmanager = {
    enable = true;
    port = 9093;
    configText = ''
      global:
        resolve_timeout: 5m

      route:
        group_by: ['alertname', 'cluster', 'service']
        group_wait: 10s
        group_interval: 10s
        repeat_interval: 1h
        receiver: 'ntfy'

      receivers:
      - name: 'ntfy'
        webhook_configs:
        - url: '${config.router.alerting.ntfyUrl}'
          send_resolved: true
    '';
  };

  # Create required directories
  systemd.tmpfiles.rules = [
    "d /var/lib/prometheus-node-exporter-text-files 0755 root root -"
  ];

  # Open firewall port for Grafana (internal access only)
  networking.firewall.interfaces.br-lan = {
    allowedTCPPorts = [
      3000 # Grafana
    ];
  };
}
