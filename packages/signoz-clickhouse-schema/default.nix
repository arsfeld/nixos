{ lib
, stdenv
, clickhouse
, writeShellScript
}:

stdenv.mkDerivation rec {
  pname = "signoz-clickhouse-schema";
  version = "0.90.1";

  # We'll create the schema inline based on SigNoz requirements
  dontUnpack = true;
  dontBuild = true;

  installPhase = ''
    mkdir -p $out/share/signoz/clickhouse
    
    # Create initialization script
    cat > $out/share/signoz/clickhouse/init-signoz-db.sh << 'EOF'
    #!/bin/bash
    set -e

    CLICKHOUSE_HOST=''${CLICKHOUSE_HOST:-localhost}
    CLICKHOUSE_PORT=''${CLICKHOUSE_PORT:-9000}
    CLICKHOUSE_USER=''${CLICKHOUSE_USER:-default}
    CLICKHOUSE_PASSWORD=''${CLICKHOUSE_PASSWORD:-}

    echo "Initializing SigNoz ClickHouse databases..."

    # Build clickhouse-client command with optional password
    CLICKHOUSE_CMD="${clickhouse}/bin/clickhouse-client --host=$CLICKHOUSE_HOST --port=$CLICKHOUSE_PORT --user=$CLICKHOUSE_USER"
    if [ -n "$CLICKHOUSE_PASSWORD" ]; then
      CLICKHOUSE_CMD="$CLICKHOUSE_CMD --password=$CLICKHOUSE_PASSWORD"
    fi

    # Create databases
    echo "Creating signoz_traces database..."
    echo "CREATE DATABASE IF NOT EXISTS signoz_traces;" | $CLICKHOUSE_CMD
    echo "Creating signoz_metrics database..."
    echo "CREATE DATABASE IF NOT EXISTS signoz_metrics;" | $CLICKHOUSE_CMD
    echo "Creating signoz_logs database..."
    echo "CREATE DATABASE IF NOT EXISTS signoz_logs;" | $CLICKHOUSE_CMD

    # Create traces tables
    $CLICKHOUSE_CMD --database=signoz_traces <<-'EOSQL'
    CREATE TABLE IF NOT EXISTS signoz_index_v2 (
      timestamp DateTime64(9) CODEC(DoubleDelta, LZ4),
      traceID String CODEC(ZSTD(1)),
      spanID String CODEC(ZSTD(1)),
      parentSpanID String CODEC(ZSTD(1)),
      serviceName LowCardinality(String) CODEC(ZSTD(1)),
      name LowCardinality(String) CODEC(ZSTD(1)),
      kind Int8 CODEC(T64, ZSTD(1)),
      durationNano UInt64 CODEC(T64, ZSTD(1)),
      statusCode Int16 CODEC(T64, ZSTD(1)),
      hasError bool CODEC(T64, ZSTD(1)),
      resourceTagsKeys Array(String) CODEC(ZSTD(1)),
      resourceTagsValues Array(String) CODEC(ZSTD(1)),
      scopeTagsKeys Array(String) CODEC(ZSTD(1)),
      scopeTagsValues Array(String) CODEC(ZSTD(1)),
      spanTagsKeys Array(String) CODEC(ZSTD(1)),
      spanTagsValues Array(String) CODEC(ZSTD(1)),
      INDEX idx_service serviceName TYPE bloom_filter GRANULARITY 4,
      INDEX idx_name name TYPE bloom_filter GRANULARITY 4,
      INDEX idx_kind kind TYPE minmax GRANULARITY 4,
      INDEX idx_duration durationNano TYPE minmax GRANULARITY 4,
      INDEX idx_hasError hasError TYPE set(2) GRANULARITY 4,
      INDEX idx_tagKeys resourceTagsKeys TYPE bloom_filter GRANULARITY 4,
      INDEX idx_tagValues resourceTagsValues TYPE bloom_filter GRANULARITY 4
    ) ENGINE = MergeTree
    PARTITION BY toDate(timestamp)
    ORDER BY (serviceName, -toUnixTimestamp64Nano(timestamp), traceID)
    TTL toDateTime(timestamp) + INTERVAL 7 DAY
    SETTINGS ttl_only_drop_parts = 1
    EOSQL

    # Create metrics tables
    echo "Creating samples_v4 table..."
    $CLICKHOUSE_CMD --database=signoz_metrics <<-'EOSQL'
    CREATE TABLE IF NOT EXISTS samples_v4 (
      metric_name LowCardinality(String),
      fingerprint UInt64,
      timestamp_ms Int64,
      value Float64,
      INDEX idx_metric_name metric_name TYPE bloom_filter GRANULARITY 4
    ) ENGINE = MergeTree
    PARTITION BY toDate(timestamp_ms / 1000)
    ORDER BY (metric_name, fingerprint, timestamp_ms)
    TTL toDateTime(timestamp_ms / 1000) + INTERVAL 30 DAY
    EOSQL

    echo "Creating time_series_v4 table..."
    $CLICKHOUSE_CMD --database=signoz_metrics <<-'EOSQL'
    CREATE TABLE IF NOT EXISTS time_series_v4 (
      metric_name LowCardinality(String),
      fingerprint UInt64,
      labels String,
      INDEX idx_labels labels TYPE bloom_filter GRANULARITY 4
    ) ENGINE = ReplacingMergeTree
    ORDER BY (metric_name, fingerprint)
    EOSQL

    # Create logs tables
    $CLICKHOUSE_CMD --database=signoz_logs <<-'EOSQL'
    CREATE TABLE IF NOT EXISTS logs (
      timestamp UInt64,
      observed_timestamp UInt64,
      id String,
      trace_id String,
      span_id String,
      trace_flags UInt32,
      severity_text LowCardinality(String),
      severity_number UInt8,
      body String,
      attributes_string_key Array(String),
      attributes_string_value Array(String),
      attributes_int64_key Array(String),
      attributes_int64_value Array(Int64),
      attributes_float64_key Array(String),
      attributes_float64_value Array(Float64),
      attributes_bool_key Array(String),
      attributes_bool_value Array(Bool),
      resources_string_key Array(String),
      resources_string_value Array(String),
      scope_name String,
      scope_version String,
      INDEX idx_trace_id trace_id TYPE bloom_filter GRANULARITY 4,
      INDEX idx_severity severity_text TYPE set(25) GRANULARITY 4,
      INDEX idx_body body TYPE tokenbf_v1(10240, 3, 0) GRANULARITY 4
    ) ENGINE = MergeTree
    PARTITION BY toDate(timestamp / 1000000000)
    ORDER BY (timestamp, id)
    TTL toDateTime(timestamp / 1000000000) + INTERVAL 7 DAY
    EOSQL

    # Create view for OTEL collector compatibility
    echo "Creating compatibility views..."
    $CLICKHOUSE_CMD --database=signoz_traces <<-'EOSQL'
    CREATE VIEW IF NOT EXISTS durationSort AS
    SELECT
      traceID AS TraceId,
      min(timestamp) AS Start,
      max(timestamp) AS End
    FROM signoz_index_v2
    WHERE traceID != ''
    GROUP BY traceID
    EOSQL

    echo "SigNoz ClickHouse initialization complete!"
    EOF
    
    chmod +x $out/share/signoz/clickhouse/init-signoz-db.sh
  '';

  meta = with lib; {
    description = "SigNoz ClickHouse schema initialization";
    homepage = "https://signoz.io";
    license = licenses.asl20;
    maintainers = with maintainers; [ ];
  };
}