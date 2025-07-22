{
  lib,
  buildGoModule,
  fetchFromGitHub,
  sqlite,
  pkg-config,
}:
buildGoModule rec {
  pname = "signoz-query-service";
  version = "0.90.1";

  src = fetchFromGitHub {
    owner = "SigNoz";
    repo = "signoz";
    rev = "v${version}";
    sha256 = "sha256-gGuUvOCzEY0WqFL7rzJQQ4lQ3IFOuU5QSxy6n6Uaq/k=";
  };

  vendorHash = "sha256-HARssGBij+rFTPXmgKn7Hdb658IHE0pzFUpCW+ZhrXE=";

  # Build only the query-service
  subPackages = ["pkg/query-service"];

  nativeBuildInputs = [pkg-config];
  buildInputs = [sqlite];

  # Need CGO for SQLite
  env.CGO_ENABLED = 1;

  # Build tags and flags from SigNoz Makefile
  tags = ["timetzdata"];

  ldflags = [
    "-s"
    "-w"
    "-X main.Version=${version}"
    "-X main.GitHash=${src.rev}"
  ];

  # Environment variables needed at runtime
  postInstall = ''
    mkdir -p $out/share/signoz

    # Move the built binary
    mv $out/bin/query-service $out/bin/signoz-query-service

    # Create a wrapper script that sets required environment variables
    cat > $out/bin/signoz-query-service-wrapped << EOF
    #!/bin/sh
    export ClickHouseUrl="\''${CLICKHOUSE_URL:-tcp://localhost:9000}"
    export STORAGE="\''${STORAGE:-clickhouse}"
    export SIGNOZ_LOCAL_DB_PATH="\''${SIGNOZ_LOCAL_DB_PATH:-/var/lib/signoz/signoz.db}"
    export ALERTMANAGER_API_PREFIX="\''${ALERTMANAGER_API_PREFIX:-http://localhost:9093/api/}"
    export DASHBOARDS_PATH="\''${DASHBOARDS_PATH:-/var/lib/signoz/dashboards}"
    export GODEBUG="netdns=go"
    export TELEMETRY_ENABLED="\''${TELEMETRY_ENABLED:-false}"
    export SIGNOZ_SELFTELEMETRY_PROMETHEUS_PORT="\''${SIGNOZ_SELFTELEMETRY_PROMETHEUS_PORT:-9091}"
    exec $out/bin/signoz-query-service "\$@"
    EOF
    chmod +x $out/bin/signoz-query-service-wrapped
  '';

  # Skip tests that require network access
  doCheck = false;

  meta = with lib; {
    description = "SigNoz Query Service - handles queries for traces, logs, and metrics";
    homepage = "https://signoz.io";
    license = licenses.asl20;
    maintainers = with maintainers; [];
  };
}
