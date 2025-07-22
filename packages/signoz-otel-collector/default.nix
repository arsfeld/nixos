{
  lib,
  buildGoModule,
  fetchFromGitHub,
}:
buildGoModule rec {
  pname = "signoz-otel-collector";
  version = "0.102.9";

  src = fetchFromGitHub {
    owner = "SigNoz";
    repo = "signoz-otel-collector";
    rev = "v${version}";
    sha256 = "sha256-pyEYWptfG5ZvXfwJHlVPQsZkjc61qY3hTjOWQMkIHRU=";
  };

  vendorHash = lib.fakeHash; # Will be set after first build attempt

  # Build the collector binary
  subPackages = ["."];

  ldflags = [
    "-s"
    "-w"
    "-X github.com/open-telemetry/opentelemetry-collector-contrib/internal/version.Version=${version}"
  ];

  # Skip tests that require network access
  doCheck = false;

  meta = with lib; {
    description = "SigNoz OpenTelemetry Collector - customized OTEL collector for SigNoz";
    homepage = "https://github.com/SigNoz/signoz-otel-collector";
    license = licenses.asl20;
    maintainers = with maintainers; [];
  };
}
