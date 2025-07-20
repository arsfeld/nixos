{ lib
, stdenv
, writeShellScript
, callPackage
}:

let
  signoz-schema-migrator = callPackage ../signoz-schema-migrator {};
in
stdenv.mkDerivation rec {
  pname = "signoz-clickhouse-schema";
  version = "0.90.1";

  dontUnpack = true;
  dontBuild = true;

  installPhase = ''
    mkdir -p $out/share/signoz/clickhouse
    
    # Create initialization script that uses the migrator
    cat > $out/share/signoz/clickhouse/init-signoz-db.sh << 'EOF'
    #!/bin/bash
    set -e

    CLICKHOUSE_HOST=''${CLICKHOUSE_HOST:-localhost}
    CLICKHOUSE_PORT=''${CLICKHOUSE_PORT:-9000}
    CLICKHOUSE_USER=''${CLICKHOUSE_USER:-default}
    CLICKHOUSE_PASSWORD=''${CLICKHOUSE_PASSWORD:-}

    echo "Initializing SigNoz ClickHouse databases using schema migrator..."

    # Build DSN
    if [ -n "$CLICKHOUSE_PASSWORD" ]; then
      DSN="tcp://$CLICKHOUSE_HOST:$CLICKHOUSE_PORT?username=$CLICKHOUSE_USER&password=$CLICKHOUSE_PASSWORD"
    else
      DSN="tcp://$CLICKHOUSE_HOST:$CLICKHOUSE_PORT?username=$CLICKHOUSE_USER"
    fi

    # Run sync migrations
    echo "Running synchronous migrations..."
    ${signoz-schema-migrator}/bin/signoz-schema-migrator sync --dsn="$DSN" --replication=false --up

    # Run async migrations
    echo "Running asynchronous migrations..."
    ${signoz-schema-migrator}/bin/signoz-schema-migrator async --dsn="$DSN" --replication=false --up

    echo "SigNoz ClickHouse initialization complete!"
    EOF

    chmod +x $out/share/signoz/clickhouse/init-signoz-db.sh
  '';

  meta = with lib; {
    description = "SigNoz ClickHouse schema initialization using official migrator";
    homepage = "https://signoz.io";
    license = licenses.asl20;
    maintainers = with maintainers; [ ];
  };
}