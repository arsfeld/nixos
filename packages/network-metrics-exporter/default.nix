{pkgs, ...}:

pkgs.buildGoModule rec {
  pname = "network-metrics-exporter";
  version = "0.1.0";

  src = ./.;

  vendorHash = "sha256-47/M5+92p9C4AZ33/pHu/zjwcxoMc06D90x8mO73FOQ=";

  ldflags = [ "-s" "-w" ];

  meta = with pkgs.lib; {
    description = "Prometheus exporter for per-client network metrics";
    license = licenses.mit;
    maintainers = [ ];
  };
}