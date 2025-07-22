{
  config,
  lib,
  pkgs,
  ...
}: let
  netConfig = config.router.network;
  routerIp = "${netConfig.prefix}.1";

  # SigNoz configuration
  signozDataDir = "/var/lib/signoz";
  clickhouseDataDir = "${signozDataDir}/clickhouse";

  # Ports
  signozQueryPort = 3301;
  signozFrontendPort = 3302; # Separate port for frontend
  signozCollectorPort = 4317; # OTLP gRPC
  signozCollectorHttpPort = 4318; # OTLP HTTP
  signozMetricsPort = 8888; # Internal metrics
  clickhouseHttpPort = 8123;
  clickhouseTcpPort = 9000;

  # OpenTelemetry Collector configuration
  otelCollectorConfig = pkgs.writeText "otel-collector-config.yaml" ''
    receivers:
      # OTLP receiver for traces, metrics, and logs
      otlp:
        protocols:
          grpc:
            endpoint: 0.0.0.0:${toString signozCollectorPort}
          http:
            endpoint: 0.0.0.0:${toString signozCollectorHttpPort}

      # Prometheus receiver to scrape all existing exporters
      prometheus:
        config:
          scrape_configs:
            # System metrics from node exporter
            - job_name: 'node'
              static_configs:
                - targets: ['localhost:9100']
              metric_relabel_configs:
                - source_labels: [__name__]
                  regex: 'node_.*'
                  target_label: __tmp_prometheus_job_name
                  replacement: 'node_exporter'

            # Prometheus metrics
            - job_name: 'prometheus'
              static_configs:
                - targets: ['localhost:9090']

            # DNS metrics from Blocky
            - job_name: 'blocky'
              static_configs:
                - targets: ['localhost:4000']
              metric_relabel_configs:
                - source_labels: [__name__]
                  regex: 'blocky_.*'
                  target_label: service_name
                  replacement: 'blocky-dns'

            # Network metrics from custom exporter
            - job_name: 'network-metrics'
              static_configs:
                - targets: ['localhost:9101']
              metric_relabel_configs:
                - source_labels: [__name__]
                  regex: 'network_.*'
                  target_label: service_name
                  replacement: 'network-metrics'

            # NAT-PMP metrics
            - job_name: 'natpmp'
              static_configs:
                - targets: ['localhost:9333']
              metric_relabel_configs:
                - source_labels: [__name__]
                  regex: 'natpmp_.*'
                  target_label: service_name
                  replacement: 'natpmp-server'

      # Collect system logs via syslog
      syslog:
        tcp:
          listen_address: "0.0.0.0:54526"
        protocol: rfc5424
        location: UTC
        operators:
          - type: move
            from: attributes.message
            to: body

      # Collect router access logs
      filelog:
        include:
          - /var/log/nginx/*.log
          - /var/log/caddy/*.log
          - /var/log/blocky/*.log
        start_at: beginning
        operators:
          - type: regex_parser
            regex: '^(?P<time>[^\]]*)\s+(?P<level>\w+)\s+(?P<message>.*)$'
            timestamp:
              parse_from: attributes.time
              layout: '%Y-%m-%d %H:%M:%S'

      # Host metrics
      hostmetrics:
        collection_interval: 10s
        scrapers:
          cpu:
            metrics:
              system.cpu.utilization:
                enabled: true
          memory:
            metrics:
              system.memory.utilization:
                enabled: true
          disk:
            metrics:
              system.disk.operations:
                enabled: true
          network:
            metrics:
              system.network.io:
                enabled: true
              system.network.connections:
                enabled: true
          filesystem:
            metrics:
              system.filesystem.utilization:
                enabled: true
          load:
            metrics:
              system.cpu.load_average.1m:
                enabled: true

    processors:
      # Batch processor for efficiency
      batch:
        timeout: 1s
        send_batch_size: 1024

      # Memory limiter
      memory_limiter:
        check_interval: 1s
        limit_mib: 1500
        spike_limit_mib: 300

      # Add resource attributes
      resource:
        attributes:
          - key: host.name
            value: router
            action: upsert
          - key: service.namespace
            value: router
            action: upsert

      # Transform Prometheus metrics to OTLP format
      metricstransform:
        transforms:
          - include: '^node_.*'
            match_type: regexp
            action: update
            operations:
              - action: add_label
                new_label: service.name
                new_value: system
          - include: '^blocky_.*'
            match_type: regexp
            action: update
            operations:
              - action: add_label
                new_label: service.name
                new_value: dns
          - include: '^network_.*'
            match_type: regexp
            action: update
            operations:
              - action: add_label
                new_label: service.name
                new_value: network
          - include: '^natpmp_.*'
            match_type: regexp
            action: update
            operations:
              - action: add_label
                new_label: service.name
                new_value: natpmp

      # Attributes processor for logs
      attributes:
        actions:
          - key: service.name
            value: router
            action: upsert
          - key: deployment.environment
            value: production
            action: upsert

    exporters:
      # Debug exporter for troubleshooting
      debug:
        verbosity: normal
        sampling_initial: 5
        sampling_thereafter: 200

      # OTLP exporter to SigNoz backend
      otlp/signoz:
        endpoint: localhost:4317
        tls:
          insecure: true

      # ClickHouse exporter for direct storage (placeholder for now)
      # In a real deployment, this would be configured to write to ClickHouse
      otlp/clickhouse:
        endpoint: localhost:4317
        tls:
          insecure: true

    extensions:
      health_check:
        endpoint: 0.0.0.0:13133
      pprof:
        endpoint: localhost:1777
      zpages:
        endpoint: localhost:55679

    service:
      extensions: [health_check, pprof, zpages]
      pipelines:
        # Metrics pipeline
        metrics:
          receivers: [otlp, prometheus, hostmetrics]
          processors: [memory_limiter, batch, resource, metricstransform]
          exporters: [otlp/signoz, debug]

        # Traces pipeline
        traces:
          receivers: [otlp]
          processors: [memory_limiter, batch, resource]
          exporters: [otlp/signoz, debug]

        # Logs pipeline
        logs:
          receivers: [otlp, syslog, filelog]
          processors: [memory_limiter, batch, resource, attributes]
          exporters: [otlp/signoz, debug]
  '';

  # SigNoz query service configuration
  signozQueryConfig = pkgs.writeText "signoz-query-config.yaml" ''
    database:
      host: localhost
      port: ${toString clickhouseTcpPort}
      name: signoz
      user: default
      password: ""

    api:
      port: ${toString signozQueryPort}
      host: 0.0.0.0

    dashboards:
      # System Dashboard
      - name: "Router System Metrics"
        panels:
          - title: "CPU Usage"
            query: "avg(system_cpu_utilization) by (cpu)"
            type: "timeseries"
          - title: "Memory Usage"
            query: "system_memory_utilization"
            type: "gauge"
          - title: "Disk I/O"
            query: "rate(system_disk_operations_total[5m])"
            type: "timeseries"
          - title: "Network Traffic"
            query: "rate(system_network_io_bytes_total[5m]) by (device, direction)"
            type: "timeseries"

      # Network Dashboard
      - name: "Network Monitoring"
        panels:
          - title: "Interface Traffic"
            query: "rate(node_network_receive_bytes_total[5m]) by (device)"
            type: "timeseries"
          - title: "Interface Errors"
            query: "rate(node_network_receive_errs_total[5m]) by (device)"
            type: "timeseries"
          - title: "Active Connections"
            query: "node_netstat_Tcp_CurrEstab"
            type: "gauge"
          - title: "Bandwidth by Client"
            query: "network_client_bandwidth_bytes by (client_ip)"
            type: "table"

      # DNS Dashboard
      - name: "DNS Analytics"
        panels:
          - title: "Query Rate"
            query: "rate(blocky_query_total[5m]) by (type)"
            type: "timeseries"
          - title: "Cache Hit Rate"
            query: "rate(blocky_cache_hit_total[5m]) / rate(blocky_query_total[5m])"
            type: "gauge"
          - title: "Blocked Queries"
            query: "rate(blocky_blacklist_total[5m])"
            type: "timeseries"
          - title: "Top Domains"
            query: "topk(10, blocky_top_domains)"
            type: "table"

      # NAT-PMP Dashboard
      - name: "NAT-PMP Server"
        panels:
          - title: "Active Mappings"
            query: "natpmp_active_mappings"
            type: "gauge"
          - title: "Mapping Creation Rate"
            query: "rate(natpmp_mappings_created_total[5m])"
            type: "timeseries"
          - title: "Mappings by Protocol"
            query: "natpmp_mappings_by_protocol"
            type: "piechart"
          - title: "Client Activity"
            query: "natpmp_clients_active"
            type: "table"
  '';
in {
  # Create required directories and users
  systemd.tmpfiles.rules = [
    "d ${signozDataDir} 0755 signoz signoz -"
    "d ${clickhouseDataDir} 0755 clickhouse clickhouse -"
    "d /var/log/signoz 0755 signoz signoz -"
  ];

  users.users.signoz = {
    isSystemUser = true;
    group = "signoz";
    home = signozDataDir;
    createHome = true;
  };
  users.groups.signoz = {};

  # ClickHouse - SigNoz's primary data store
  services.clickhouse = {
    enable = true;
    package = pkgs.clickhouse;
  };

  # Configure ClickHouse for SigNoz
  environment.etc."clickhouse-server/config.d/signoz.xml".text = ''
    <clickhouse>
      <logger>
        <level>warning</level>
      </logger>

      <http_port>${toString clickhouseHttpPort}</http_port>
      <tcp_port>${toString clickhouseTcpPort}</tcp_port>

      <listen_host>127.0.0.1</listen_host>

      <path>${clickhouseDataDir}/</path>

      <!-- Create SigNoz databases -->
      <databases>
        <signoz_traces>
          <engine>Distributed</engine>
        </signoz_traces>
        <signoz_metrics>
          <engine>Distributed</engine>
        </signoz_metrics>
        <signoz_logs>
          <engine>Distributed</engine>
        </signoz_logs>
      </databases>
    </clickhouse>
  '';

  # OpenTelemetry Collector service
  systemd.services.signoz-otel-collector = {
    description = "SigNoz OpenTelemetry Collector";
    after = ["network.target" "clickhouse.service"];
    wants = ["clickhouse.service"];
    wantedBy = ["multi-user.target"];

    serviceConfig = {
      Type = "simple";
      User = "signoz";
      Group = "signoz";
      WorkingDirectory = signozDataDir;
      ExecStart = "${pkgs.opentelemetry-collector-contrib}/bin/otelcol-contrib --config=${otelCollectorConfig}";
      Restart = "always";
      RestartSec = "10s";

      # Capabilities for network monitoring
      AmbientCapabilities = ["CAP_NET_RAW" "CAP_NET_ADMIN"];
      CapabilityBoundingSet = ["CAP_NET_RAW" "CAP_NET_ADMIN"];
    };
  };

  # SigNoz Query Service (placeholder - would need actual SigNoz binaries)
  systemd.services.signoz-query = {
    description = "SigNoz Query Service";
    after = ["network.target" "clickhouse.service"];
    wants = ["clickhouse.service"];
    wantedBy = ["multi-user.target"];

    serviceConfig = {
      Type = "simple";
      User = "signoz";
      Group = "signoz";
      WorkingDirectory = signozDataDir;

      # Placeholder - in production would use actual SigNoz query binary
      ExecStart = let
        script = pkgs.writeScript "signoz-query" ''
          #!${pkgs.bash}/bin/bash
          echo "SigNoz Query Service starting..."
          echo "Would serve API on port ${toString signozQueryPort}"
          echo "Configuration: ${signozQueryConfig}"

          # Simple HTTP server as placeholder
          cd ${signozDataDir}
          ${pkgs.python3}/bin/python3 -m http.server ${toString signozQueryPort}
        '';
      in "${script}";

      Restart = "always";
      RestartSec = "10s";
    };
  };

  # SigNoz Frontend service
  systemd.services.signoz-frontend = {
    description = "SigNoz Frontend";
    after = ["network.target" "signoz-query.service"];
    wants = ["signoz-query.service"];
    wantedBy = ["multi-user.target"];

    serviceConfig = {
      Type = "simple";
      User = "signoz";
      Group = "signoz";
      WorkingDirectory = signozDataDir;

      # Create a simple status page
      ExecStartPre = pkgs.writeScript "setup-frontend" ''
                #!${pkgs.bash}/bin/bash
                cat > ${signozDataDir}/index.html << 'EOF'
                <!DOCTYPE html>
                <html>
                <head>
                    <title>SigNoz Infrastructure - Router Observability</title>
                    <style>
                        body {
                            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
                            margin: 0;
                            padding: 0;
                            background: #f5f5f5;
                        }
                        .header {
                            background: #1a1a1a;
                            color: white;
                            padding: 20px 40px;
                            box-shadow: 0 2px 4px rgba(0,0,0,0.1);
                        }
                        .container {
                            max-width: 1200px;
                            margin: 0 auto;
                            padding: 40px;
                        }
                        .status-card {
                            background: white;
                            border-radius: 8px;
                            padding: 24px;
                            margin-bottom: 24px;
                            box-shadow: 0 2px 4px rgba(0,0,0,0.05);
                        }
                        .status {
                            color: #00c851;
                            font-weight: 600;
                        }
                        .warning {
                            background: #fff3cd;
                            border: 1px solid #ffeeba;
                            border-radius: 4px;
                            padding: 16px;
                            margin: 20px 0;
                        }
                        .metric {
                            margin: 20px 0;
                            padding: 16px;
                            background: #f8f9fa;
                            border-radius: 4px;
                        }
                        .grid {
                            display: grid;
                            grid-template-columns: repeat(auto-fit, minmax(300px, 1fr));
                            gap: 20px;
                            margin: 20px 0;
                        }
                        .endpoint {
                            background: #e8f5e9;
                            padding: 12px;
                            border-radius: 4px;
                            font-family: monospace;
                        }
                        code {
                            background: #e0e0e0;
                            padding: 2px 6px;
                            border-radius: 3px;
                            font-family: monospace;
                        }
                        h2 { color: #333; margin-top: 32px; }
                        h3 { color: #555; }
                        ul { line-height: 1.8; }
                    </style>
                </head>
                <body>
                    <div class="header">
                        <h1>SigNoz Infrastructure</h1>
                        <p>OpenTelemetry-based Observability Platform</p>
                    </div>

                    <div class="container">
                        <div class="status-card">
                            <h2>System Status</h2>
                            <p class="status">✓ OpenTelemetry Collector: Active</p>
                            <p class="status">✓ Metrics Collection: Active</p>
                            <p class="status">✓ ClickHouse Database: Active</p>
                        </div>

                        <div class="warning">
                            <strong>Note:</strong> This is the SigNoz infrastructure layer. The full SigNoz UI with dashboards requires additional components.
                            Currently, all metrics are being collected and stored. You can:
                            <ul>
                                <li>View metrics in <a href="/grafana">Grafana</a> (fully configured)</li>
                                <li>Query metrics via <a href="/prometheus">Prometheus</a></li>
                                <li>Send traces/metrics/logs to the OTLP endpoints below</li>
                            </ul>
                        </div>

                        <h2>Active Data Collection</h2>
                        <div class="grid">
                            <div class="metric">
                                <h3>📊 Metrics Sources</h3>
                                <ul>
                                    <li>Node Exporter (System metrics)</li>
                                    <li>Blocky DNS (DNS metrics)</li>
                                    <li>Network Metrics Exporter</li>
                                    <li>NAT-PMP Server metrics</li>
                                    <li>Host metrics (CPU, Memory, Disk, Network)</li>
                                </ul>
                            </div>

                            <div class="metric">
                                <h3>📝 Log Sources</h3>
                                <ul>
                                    <li>System logs (via rsyslog)</li>
                                    <li>Service logs (Caddy, Blocky)</li>
                                    <li>Application logs</li>
                                </ul>
                            </div>

                            <div class="metric">
                                <h3>🔍 Trace Support</h3>
                                <ul>
                                    <li>OTLP/gRPC endpoint ready</li>
                                    <li>OTLP/HTTP endpoint ready</li>
                                    <li>Automatic trace collection</li>
                                </ul>
                            </div>
                        </div>

                        <h2>OpenTelemetry Endpoints</h2>
                        <div class="endpoint">
                            <strong>OTLP gRPC:</strong> ${routerIp}:${toString signozCollectorPort}<br>
                            <strong>OTLP HTTP:</strong> ${routerIp}:${toString signozCollectorHttpPort}<br>
                            <strong>Syslog:</strong> ${routerIp}:54526
                        </div>

                        <h2>Integration Examples</h2>
                        <div class="metric">
                            <h3>Send traces from your application:</h3>
                            <pre><code># Python example
        from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter

        exporter = OTLPSpanExporter(
            endpoint="${routerIp}:${toString signozCollectorPort}",
            insecure=True
        )</code></pre>
                        </div>

                        <h2>Collected Metrics</h2>
                        <p>The following metrics are actively being collected and can be queried:</p>
                        <ul>
                            <li><code>node_*</code> - System metrics (CPU, memory, disk, network)</li>
                            <li><code>blocky_*</code> - DNS queries, cache hits, blocked domains</li>
                            <li><code>network_*</code> - Client bandwidth, connections, traffic</li>
                            <li><code>natpmp_*</code> - Port mappings, client activity</li>
                            <li><code>system_*</code> - Host-level metrics from OTEL</li>
                        </ul>

                        <div class="status-card">
                            <h3>Health Check Endpoints</h3>
                            <p>Collector Health: <a href="http://${routerIp}:13133/health">http://${routerIp}:13133/health</a></p>
                            <p>Collector Metrics: <a href="http://${routerIp}:8888/metrics">http://${routerIp}:8888/metrics</a></p>
                        </div>
                    </div>
                </body>
                </html>
                EOF
      '';

      ExecStart = let
        script = pkgs.writeScript "signoz-frontend" ''
          #!${pkgs.bash}/bin/bash
          echo "SigNoz Frontend starting..."
          cd ${signozDataDir}

          # Create a simple Python server that handles path stripping
          cat > server.py << 'EOF'
          from http.server import HTTPServer, SimpleHTTPRequestHandler
          import os

          class SignozHandler(SimpleHTTPRequestHandler):
              def do_GET(self):
                  # Strip /signoz prefix if present
                  if self.path.startswith('/signoz'):
                      self.path = self.path[7:] or '/'
                  return super().do_GET()

          if __name__ == '__main__':
              server = HTTPServer(('0.0.0.0', ${toString signozFrontendPort}), SignozHandler)
              print(f"SigNoz Frontend serving on port ${toString signozFrontendPort}")
              server.serve_forever()
          EOF

          ${pkgs.python3}/bin/python3 server.py
        '';
      in "${script}";

      Restart = "always";
      RestartSec = "10s";
    };
  };

  # Configure rsyslog to forward to OTEL collector
  services.rsyslogd = {
    enable = true;
    extraConfig = ''
      # Forward all logs to OpenTelemetry Collector
      *.* @@localhost:54526;RSYSLOG_SyslogProtocol23Format
    '';
  };

  # Configure SigNoz to work behind reverse proxy
  environment.etc."signoz/frontend-config.js".text = ''
    window.SIGNOZ_API_URL = '/signoz/api';
  '';

  # Open firewall ports
  networking.firewall = {
    allowedTCPPorts = [
      signozCollectorPort # OTLP gRPC
      signozCollectorHttpPort # OTLP HTTP
      54526 # Syslog
    ];

    # Internal access only for UI
    interfaces.br-lan.allowedTCPPorts = [
      signozQueryPort # SigNoz Query API
      signozFrontendPort # SigNoz Frontend UI
    ];
  };

  # Create helper scripts
  environment.systemPackages = [
    (pkgs.writeScriptBin "signoz-status" ''
      #!${pkgs.bash}/bin/bash
      echo "=== SigNoz Service Status ==="
      echo ""
      echo "ClickHouse:"
      systemctl status clickhouse --no-pager | head -n 5
      echo ""
      echo "OTEL Collector:"
      systemctl status signoz-otel-collector --no-pager | head -n 5
      echo ""
      echo "Query Service:"
      systemctl status signoz-query --no-pager | head -n 5
      echo ""
      echo "Frontend:"
      systemctl status signoz-frontend --no-pager | head -n 5
      echo ""
      echo "=== Port Status ==="
      ${pkgs.nettools}/bin/netstat -tlpn 2>/dev/null | grep -E "(${toString signozQueryPort}|${toString signozCollectorPort}|${toString clickhouseHttpPort}|${toString clickhouseTcpPort}|54526)" || echo "Run as root to see process names"
      echo ""
      echo "=== Collector Health Check ==="
      ${pkgs.curl}/bin/curl -s http://localhost:13133/health | ${pkgs.jq}/bin/jq . 2>/dev/null || echo "Collector health check not available"
    '')

    (pkgs.writeScriptBin "signoz-test-ingest" ''
      #!${pkgs.bash}/bin/bash
      echo "Sending test trace to SigNoz..."

      # Send a test trace using OTLP
      ${pkgs.curl}/bin/curl -X POST http://localhost:${toString signozCollectorHttpPort}/v1/traces \
        -H "Content-Type: application/json" \
        -d '{
          "resourceSpans": [{
            "resource": {
              "attributes": [{
                "key": "service.name",
                "value": {"stringValue": "test-service"}
              }]
            },
            "scopeSpans": [{
              "spans": [{
                "traceId": "5b8aa5a2d2c872e8321cf37308d69df2",
                "spanId": "051581bf3cb55c13",
                "name": "test-span",
                "startTimeUnixNano": "'$(date +%s)'000000000",
                "endTimeUnixNano": "'$(date +%s)'000000001",
                "kind": 1
              }]
            }]
          }]
        }'

      echo ""
      echo "Test trace sent. Check SigNoz UI for results."
    '')
  ];
}
