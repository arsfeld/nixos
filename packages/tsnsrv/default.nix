{pkgs, ...}:
pkgs.buildGo125Module {
  pname = "tsnsrv";
  version = "0.0.0";

  src = pkgs.lib.sourceFilesBySuffices (pkgs.lib.sources.cleanSource ./src) [
    ".go"
    ".mod"
    ".sum"
  ];

  vendorHash = "sha256-Mp6Cz7Gtqxto4LqzJiZQd2SbaTabJRmoWOMF++MIPI4=";

  subPackages = ["cmd/tsnsrv"];

  ldflags = ["-s" "-w"];

  meta = with pkgs.lib; {
    description = "Tailscale reverse proxy service";
    homepage = "https://github.com/arsfeld/tsnsrv";
    mainProgram = "tsnsrv";
  };
}
