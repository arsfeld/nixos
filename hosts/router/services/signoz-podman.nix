{ config, lib, pkgs, ... }:

let
  # OTEL Collector configuration
  otelCollectorConfig = pkgs.writeText "otel-collector-config.yaml" ''
    receivers:
      otlp:
        protocols:
          grpc:
            endpoint: 0.0.0.0:4317
          http:
            endpoint: 0.0.0.0:4318
      
      prometheus:
        config:
          scrape_configs:
            # Scrape Node Exporter
            - job_name: 'node'
              static_configs:
                - targets: ['localhost:9100']
            
            # Scrape Blocky DNS
            - job_name: 'blocky'
              static_configs:
                - targets: ['localhost:4000']
              metrics_path: '/metrics'
            
            # Scrape Network Exporter
            - job_name: 'network'
              static_configs:
                - targets: ['localhost:9109']
            
            # Scrape NAT-PMP
            - job_name: 'natpmp'
              static_configs:
                - targets: ['localhost:9111']

    processors:
      batch:
        send_batch_size: 10000
        timeout: 10s
      
      memory_limiter:
        check_interval: 1s
        limit_mib: 1000
        spike_limit_mib: 200
      
      resource:
        attributes:
          - key: host.name
            value: router
            action: insert
          - key: service.name
            from_attribute: service_name
            action: insert

    exporters:
      clickhousetraces:
        datasource: tcp://localhost:9000/signoz_traces
      
      clickhousemetricswrite:
        endpoint: tcp://localhost:9000
        resource_to_telemetry_conversion:
          enabled: true
      
      clickhouselogsexporter:
        dsn: tcp://localhost:9000/signoz_logs
        timeout: 10s

    service:
      pipelines:
        traces:
          receivers: [otlp]
          processors: [batch, memory_limiter, resource]
          exporters: [clickhousetraces]
        
        metrics:
          receivers: [otlp, prometheus]
          processors: [batch, memory_limiter, resource]
          exporters: [clickhousemetricswrite]
        
        logs:
          receivers: [otlp]
          processors: [batch, memory_limiter, resource]
          exporters: [clickhouselogsexporter]
  '';
in
{
  # Ensure ZooKeeper is enabled for ClickHouse
  services.zookeeper = {
    enable = true;
    dataDir = "/var/lib/zookeeper";
  };

  # Ensure ClickHouse is configured properly
  services.clickhouse = {
    enable = true;
  };

  # Create required directories
  systemd.tmpfiles.rules = [
    "d /var/lib/signoz 0755 root root -"
    "d /var/lib/signoz/sqlite 0755 root root -"
    "d /etc/otel-collector 0755 root root -"
    "d /var/lib/clickhouse/user_scripts 0755 clickhouse clickhouse -"
  ];

  # Place OTEL collector config
  environment.etc."otel-collector/config.yaml".source = otelCollectorConfig;

  # Container definitions for SigNoz components
  virtualisation.oci-containers.containers = {
    # Query Service - Main backend API
    signoz-query-service = {
      image = "signoz/signoz:v0.90.1";
      
      environment = {
        # Match official Docker Compose environment
        SIGNOZ_TELEMETRYSTORE_CLICKHOUSE_DSN = "tcp://localhost:9000";
        SIGNOZ_SQLSTORE_SQLITE_PATH = "/var/lib/signoz/signoz.db";
        STORAGE = "clickhouse";
        GODEBUG = "netdns=go";
        TELEMETRY_ENABLED = "false";
        DEPLOYMENT_TYPE = "docker-standalone-amd";
        DOT_METRICS_ENABLED = "true";
        ZOOKEEPER_SERVERS = "localhost:2181";
        QUERY_SERVICE_PORT = "8080";
        # Alertmanager integration
        SIGNOZ_ALERTMANAGER_PROVIDER = "signoz";
      };
      
      ports = [ 
        "8080:8080"  # Query API
        "3301:3301"  # Frontend UI
      ];
      
      extraOptions = [ 
        "--network=host"
        "--add-host=host.containers.internal:127.0.0.1"
      ];
      
      volumes = [
        "/var/lib/signoz/sqlite:/var/lib/signoz:rw"
      ];
      
      dependsOn = [ "signoz-otel-collector" ];
    };


    # OTEL Collector - Telemetry ingestion
    signoz-otel-collector = {
      image = "signoz/signoz-otel-collector:v0.128.2";
      
      environment = {
        OTEL_RESOURCE_ATTRIBUTES = "host.name=router,os.type=linux";
        DOCKER_MULTI_NODE_CLUSTER = "false";
        LOW_CARDINAL_EXCEPTION_GROUPING = "false";
        SIGNOZ_COMPONENT = "otel-collector";
      };
      
      ports = [
        "4317:4317"  # OTLP gRPC
        "4318:4318"  # OTLP HTTP
      ];
      
      volumes = [
        "/etc/otel-collector/config.yaml:/etc/otel-collector/config.yaml:ro"
        "/var/lib/signoz:/var/lib/signoz:rw"
      ];
      
      cmd = [ 
        "--config=/etc/otel-collector/config.yaml"
        "--feature-gates=-pkg.translator.prometheus.NormalizeName"
      ];
      
      extraOptions = [ 
        "--network=host"
        "--add-host=host.containers.internal:127.0.0.1"
      ];
    };

    # Schema migrator is handled separately as a oneshot service below
  };

  # Configure Caddy reverse proxy for SigNoz
  services.caddy.virtualHosts."router.bat-boa.ts.net".extraConfig = lib.mkAfter ''
    # SigNoz Web UI
    handle_path /signoz* {
      reverse_proxy localhost:3301
    }
    
    # SigNoz API (if needed for direct access)
    handle_path /api/v1/* {
      reverse_proxy localhost:8080
    }
  '';

  # Open firewall ports for OTLP
  networking.firewall.allowedTCPPorts = [ 
    4317  # OTLP gRPC
    4318  # OTLP HTTP
    3301  # SigNoz Frontend UI
    8080  # SigNoz Query Service API
  ];

  # Initialize ClickHouse with histogram quantile function
  systemd.services.clickhouse-histogram-init = {
    description = "Initialize ClickHouse Histogram Quantile Function";
    after = [ "clickhouse.service" ];
    requires = [ "clickhouse.service" ];
    before = [ "signoz-schema-init.service" ];
    
    script = ''
      # Wait for ClickHouse to be ready
      for i in {1..30}; do
        if ${pkgs.clickhouse}/bin/clickhouse-client -q "SELECT 1" >/dev/null 2>&1; then
          break
        fi
        echo "Waiting for ClickHouse to be ready..."
        sleep 2
      done

      # Check if histogram quantile function exists
      if [ ! -f /var/lib/clickhouse/user_scripts/libhistogram_quantile.so ]; then
        echo "Downloading histogram quantile function..."
        mkdir -p /var/lib/clickhouse/user_scripts
        ${pkgs.curl}/bin/curl -L https://github.com/SigNoz/uffc/releases/download/v0.1.0/histogram_quantile-amd64.so \
          -o /var/lib/clickhouse/user_scripts/libhistogram_quantile.so
        chmod 755 /var/lib/clickhouse/user_scripts/libhistogram_quantile.so
        chown clickhouse:clickhouse /var/lib/clickhouse/user_scripts/libhistogram_quantile.so
      fi
    '';
    
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
  };

  # Schema migration as a oneshot service
  systemd.services.signoz-schema-init = {
    description = "Initialize SigNoz ClickHouse Schema";
    after = [ "clickhouse.service" "zookeeper.service" "clickhouse-histogram-init.service" ];
    requires = [ "clickhouse.service" "zookeeper.service" "clickhouse-histogram-init.service" ];
    
    script = ''
      # Wait for ClickHouse to be ready
      for i in {1..30}; do
        if ${pkgs.clickhouse}/bin/clickhouse-client -q "SELECT 1" >/dev/null 2>&1; then
          break
        fi
        echo "Waiting for ClickHouse to be ready..."
        sleep 2
      done

      # Check if schema already exists
      if ${pkgs.clickhouse}/bin/clickhouse-client -q "SHOW DATABASES" | grep -q "signoz_traces"; then
        echo "SigNoz schema already exists, skipping migration"
        exit 0
      fi

      echo "Running SigNoz schema migration..."
      ${pkgs.podman}/bin/podman run --rm \
        --network=host \
        --add-host=host.containers.internal:127.0.0.1 \
        signoz/signoz-schema-migrator:v0.128.2 \
        --dsn=tcp://localhost:9000 \
        --replication=false \
        --cluster-name= \
        --up
    '';
    
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
  };

  # Ensure containers start after schema is initialized
  systemd.services.podman-signoz-query-service.after = [ "signoz-schema-init.service" ];
  systemd.services.podman-signoz-query-service.requires = [ "signoz-schema-init.service" ];
}