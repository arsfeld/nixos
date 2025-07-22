{pkgs, ...}:
pkgs.buildGoModule rec {
  pname = "network-metrics-exporter";
  version = "0.1.0";

  src = ./.;

  vendorHash = "sha256-Dm5JUQJXXMCDrDL7OCaKaTRwJIPqrUeYFfHj+9Gh+7g=";

  ldflags = ["-s" "-w"];

  meta = with pkgs.lib; {
    description = "Prometheus exporter for per-client network metrics";
    license = licenses.mit;
    maintainers = [];
  };
}
