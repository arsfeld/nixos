{
  config,
  lib,
  pkgs,
  self,
  ...
}: let
  netConfig = config.router.network;
  routerIp = "${netConfig.prefix}.1";
  
  # SigNoz configuration
  signozDataDir = "/var/lib/signoz";
  clickhouseDataDir = "${signozDataDir}/clickhouse";
  
  # Ports
  signozQueryPort = 8080;  # Standard SigNoz query service port
  signozFrontendPort = 3301;
  signozCollectorPort = 4317;  # OTLP gRPC
  signozCollectorHttpPort = 4318;  # OTLP HTTP
  signozMetricsPort = 8888;     # Internal metrics
  clickhouseHttpPort = 8123;
  clickhouseTcpPort = 9000;
  
  # Build the packages
  signoz-query-service = pkgs.callPackage (self + "/packages/signoz-query-service") {};
  signoz-frontend = pkgs.callPackage (self + "/packages/signoz-frontend") {};
  # Use nixpkgs opentelemetry-collector-contrib instead of custom build
  signoz-otel-collector = pkgs.opentelemetry-collector-contrib;
  signoz-clickhouse-schema = pkgs.callPackage (self + "/packages/signoz-clickhouse-schema") {};
  
  # OpenTelemetry Collector configuration for SigNoz
  otelCollectorConfig = pkgs.writeText "signoz-otel-config.yaml" ''
    receivers:
      otlp:
        protocols:
          grpc:
            endpoint: 0.0.0.0:${toString signozCollectorPort}
          http:
            endpoint: 0.0.0.0:${toString signozCollectorHttpPort}
      
      prometheus:
        config:
          scrape_configs:
            - job_name: 'node'
              static_configs:
                - targets: ['localhost:9100']
            - job_name: 'blocky'
              static_configs:
                - targets: ['localhost:4000']
            - job_name: 'network-metrics'
              static_configs:
                - targets: ['localhost:9101']
            - job_name: 'natpmp'
              static_configs:
                - targets: ['localhost:9333']
    
    processors:
      batch:
        send_batch_size: 10000
        send_batch_max_size: 11000
        timeout: 10s
      
      memory_limiter:
        check_interval: 5s
        limit_percentage: 80
        spike_limit_percentage: 25
      
      resource:
        attributes:
          - key: host.name
            value: router
            action: upsert
    
    exporters:
      clickhouse:
        endpoint: tcp://localhost:${toString clickhouseTcpPort}
        database: signoz_traces
        logs_table_name: logs
        traces_table_name: signoz_index_v2
        metrics_table_name: samples_v4
        ttl: 72h
      
      prometheus:
        endpoint: "0.0.0.0:8889"
        namespace: signoz
    
    extensions:
      health_check:
        endpoint: 0.0.0.0:13133
        path: "/health"
      
      zpages:
        endpoint: 0.0.0.0:55679
    
    service:
      extensions: [health_check, zpages]
      pipelines:
        traces:
          receivers: [otlp]
          processors: [memory_limiter, batch, resource]
          exporters: [clickhouse]
        
        metrics:
          receivers: [otlp, prometheus]
          processors: [memory_limiter, batch, resource]
          exporters: [clickhouse, prometheus]
        
        logs:
          receivers: [otlp]
          processors: [memory_limiter, batch, resource]
          exporters: [clickhouse]
  '';
in {
  imports = if self != null then [
    "${self}/packages/network-metrics-exporter/module.nix"
  ] else [
    ../../../packages/network-metrics-exporter/module.nix
  ];

  # Create required directories and users
  systemd.tmpfiles.rules = [
    "d ${signozDataDir} 0755 signoz signoz -"
    "d ${signozDataDir}/dashboards 0755 signoz signoz -"
    "d ${clickhouseDataDir} 0755 clickhouse clickhouse -"
    "d /var/log/signoz 0755 signoz signoz -"
    "d /etc/signoz 0755 signoz signoz -"
    "L+ /etc/signoz/web - - - - ${signoz-frontend}/share/signoz-frontend"
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
      
      <listen_host>0.0.0.0</listen_host>
      
      <path>${clickhouseDataDir}/</path>
      
      <users>
        <default>
          <password></password>
          <networks>
            <ip>::/0</ip>
          </networks>
          <profile>default</profile>
          <quota>default</quota>
          <access_management>1</access_management>
        </default>
      </users>
    </clickhouse>
  '';

  # Initialize ClickHouse schema for SigNoz
  systemd.services.signoz-clickhouse-init = {
    description = "Initialize SigNoz ClickHouse Schema";
    after = [ "clickhouse.service" ];
    requires = [ "clickhouse.service" ];
    wantedBy = [ "multi-user.target" ];
    
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      User = "clickhouse";
      Group = "clickhouse";
      ExecStart = "${signoz-clickhouse-schema}/share/signoz/clickhouse/init-signoz-db.sh";
      
      # Retry a few times in case ClickHouse is still starting
      Restart = "on-failure";
      RestartSec = "10s";
      StartLimitBurst = "5";
    };
    
    environment = {
      CLICKHOUSE_HOST = "localhost";
      CLICKHOUSE_PORT = toString clickhouseTcpPort;
    };
  };

  # SigNoz Query Service
  systemd.services.signoz-query = {
    description = "SigNoz Query Service";
    after = [ "network.target" "clickhouse.service" "signoz-clickhouse-init.service" ];
    requires = [ "clickhouse.service" ];
    wantedBy = [ "multi-user.target" ];
    
    serviceConfig = {
      Type = "simple";
      User = "signoz";
      Group = "signoz";
      WorkingDirectory = signozDataDir;
      ExecStart = "${signoz-query-service}/bin/signoz-query-service-wrapped -config=/dev/null";
      Restart = "always";
      RestartSec = "10s";
    };
    
    environment = {
      CLICKHOUSE_URL = "tcp://localhost:${toString clickhouseTcpPort}";
      STORAGE = "clickhouse";
      SIGNOZ_LOCAL_DB_PATH = "${signozDataDir}/signoz.db";
      ALERTMANAGER_API_PREFIX = "http://localhost:9093/api/";
      DASHBOARDS_PATH = "${signozDataDir}/dashboards";
      GODEBUG = "netdns=go";
      TELEMETRY_ENABLED = "false";
      DEPLOYMENT_TYPE = "nixos";
      SIGNOZ_SELFTELEMETRY_PROMETHEUS_PORT = "9091";  # Avoid conflict with main Prometheus
      SIGNOZ_SELFTELEMETRY_ENABLED = "false";  # Disable prometheus exporter to avoid port conflicts
    };
  };

  # SigNoz Frontend
  systemd.services.signoz-frontend = {
    description = "SigNoz Frontend";
    after = [ "network.target" "signoz-query.service" ];
    wants = [ "signoz-query.service" ];
    wantedBy = [ "multi-user.target" ];
    
    serviceConfig = {
      Type = "simple";
      User = "signoz";
      Group = "signoz";
      WorkingDirectory = "${signoz-frontend}/share/signoz-frontend";
      ExecStart = "${signoz-frontend}/bin/signoz-frontend";
      Restart = "always";
      RestartSec = "10s";
    };
    
    environment = {
      PORT = toString signozFrontendPort;
      QUERY_SERVICE_URL = "http://localhost:${toString signozQueryPort}";
      ALERTMANAGER_URL = "http://localhost:9093";
    };
  };

  # SigNoz OpenTelemetry Collector
  systemd.services.signoz-otel-collector = {
    description = "SigNoz OpenTelemetry Collector";
    after = [ "network.target" "clickhouse.service" "signoz-clickhouse-init.service" ];
    requires = [ "clickhouse.service" ];
    wantedBy = [ "multi-user.target" ];
    
    serviceConfig = {
      Type = "simple";
      User = "signoz";
      Group = "signoz";
      WorkingDirectory = signozDataDir;
      ExecStart = "${signoz-otel-collector}/bin/otelcol-contrib --config=${otelCollectorConfig}";
      Restart = "always";
      RestartSec = "10s";
      
      # Capabilities for network monitoring
      AmbientCapabilities = [ "CAP_NET_RAW" "CAP_NET_ADMIN" ];
      CapabilityBoundingSet = [ "CAP_NET_RAW" "CAP_NET_ADMIN" ];
    };
    
    environment = {
      OTEL_RESOURCE_ATTRIBUTES = "host.name=router,deployment.environment=production";
    };
  };

  # Prometheus Alertmanager for SigNoz
  services.prometheus.alertmanager = {
    enable = true;
    port = 9093;
    
    configuration = {
      global = {
        resolve_timeout = "5m";
      };
      
      route = {
        group_by = ["alertname" "cluster" "service"];
        group_wait = "10s";
        group_interval = "10s";
        repeat_interval = "1h";
        receiver = "default";
      };
      
      receivers = [
        {
          name = "default";
          webhook_configs = lib.optional (config.router.alerting.ntfyUrl != null) {
            url = config.router.alerting.ntfyUrl;
            send_resolved = true;
          };
        }
      ];
    };
  };

  # Configure Caddy reverse proxy for SigNoz
  services.caddy.virtualHosts = lib.mkIf (config.services.caddy.enable) {
    "http://${routerIp}".extraConfig = lib.mkAfter ''
      # SigNoz Frontend
      handle /signoz* {
        uri strip_prefix /signoz
        reverse_proxy localhost:${toString signozFrontendPort}
      }
      
      # SigNoz API
      handle /api* {
        reverse_proxy localhost:${toString signozQueryPort}
      }
    '';
    
    "router.bat-boa.ts.net".extraConfig = lib.mkAfter ''
      # SigNoz Frontend
      handle /signoz* {
        uri strip_prefix /signoz
        reverse_proxy localhost:${toString signozFrontendPort}
      }
      
      # SigNoz API
      handle /api* {
        reverse_proxy localhost:${toString signozQueryPort}
      }
    '';
  };

  # Open firewall ports
  networking.firewall = {
    allowedTCPPorts = [
      signozCollectorPort  # OTLP gRPC
      signozCollectorHttpPort  # OTLP HTTP
    ];
    
    # Internal access only for UI and ClickHouse
    interfaces.br-lan.allowedTCPPorts = [
      signozFrontendPort   # SigNoz Frontend
      signozQueryPort      # SigNoz Query API
      clickhouseHttpPort   # ClickHouse HTTP
    ];
  };

  # Create helper scripts
  environment.systemPackages = [
    (pkgs.writeScriptBin "signoz-status" ''
      #!${pkgs.bash}/bin/bash
      echo "=== SigNoz Service Status ==="
      echo ""
      
      for service in clickhouse signoz-clickhouse-init signoz-query signoz-frontend signoz-otel-collector prometheus-alertmanager; do
        echo "$service:"
        systemctl status $service --no-pager | head -n 5
        echo ""
      done
      
      echo "=== Port Status ==="
      ${pkgs.nettools}/bin/netstat -tlpn 2>/dev/null | grep -E "(${toString signozFrontendPort}|${toString signozQueryPort}|${toString signozCollectorPort}|${toString clickhouseHttpPort}|${toString clickhouseTcpPort})" || echo "Run as root to see process names"
      echo ""
      
      echo "=== Collector Health Check ==="
      ${pkgs.curl}/bin/curl -s http://localhost:13133/health || echo "Collector health check failed"
      echo ""
      
      echo "=== SigNoz URLs ==="
      echo "Frontend: http://${routerIp}:${toString signozFrontendPort}"
      echo "Query API: http://${routerIp}:${toString signozQueryPort}"
      echo "OTLP Endpoint: ${routerIp}:${toString signozCollectorPort}"
    '')
    
    (pkgs.writeScriptBin "signoz-test-trace" ''
      #!${pkgs.bash}/bin/bash
      echo "Sending test trace to SigNoz..."
      
      # Generate a random trace ID
      TRACE_ID=$(${pkgs.openssl}/bin/openssl rand -hex 16)
      SPAN_ID=$(${pkgs.openssl}/bin/openssl rand -hex 8)
      
      ${pkgs.curl}/bin/curl -X POST http://localhost:${toString signozCollectorHttpPort}/v1/traces \
        -H "Content-Type: application/json" \
        -d '{
          "resourceSpans": [{
            "resource": {
              "attributes": [{
                "key": "service.name",
                "value": {"stringValue": "test-service"}
              }, {
                "key": "host.name",
                "value": {"stringValue": "router"}
              }]
            },
            "scopeSpans": [{
              "scope": {
                "name": "test-scope"
              },
              "spans": [{
                "traceId": "'$TRACE_ID'",
                "spanId": "'$SPAN_ID'",
                "name": "test-operation",
                "kind": 2,
                "startTimeUnixNano": "'$(date +%s)'000000000",
                "endTimeUnixNano": "'$(date +%s)'000000001",
                "attributes": [{
                  "key": "http.method",
                  "value": {"stringValue": "GET"}
                }, {
                  "key": "http.url",
                  "value": {"stringValue": "/test"}
                }],
                "status": {
                  "code": 1
                }
              }]
            }]
          }]
        }'
      
      echo ""
      echo "Test trace sent with ID: $TRACE_ID"
      echo "Check SigNoz UI at http://${routerIp}/signoz"
    '')
  ];
}