{
  lib,
  buildGoModule,
  fetchFromGitHub,
}:
buildGoModule rec {
  pname = "natpmp-server";
  version = "0.1.0";

  src = ./.;

  vendorHash = "sha256-zY89D8QpzMLEk4WGYJs8i25ryq4cmZaqA3W10BZ9irs=";

  ldflags = ["-s" "-w"];

  # Skip tests to speed up build
  doCheck = false;

  meta = with lib; {
    description = "Lightweight NAT-PMP server for NixOS routers";
    homepage = "https://github.com/arsfeld/natpmp-server";
    license = licenses.mit;
    maintainers = with maintainers; [];
    mainProgram = "natpmp-server";
  };
}
