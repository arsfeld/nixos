{pkgs, ...}:
pkgs.stdenv.mkDerivation rec {
  pname = "omada-controller";
  version = "6.0.0.24";

  src = pkgs.fetchurl {
    url = "https://static.tp-link.com/upload/software/2025/202510/20251031/Omada_SDN_Controller_v${version}_linux_x64_20251027202524.tar.gz";
    sha256 = "163314619e499d2bf390f78450be6a5507cc28428fabea4312b5e61fe2b19dfa";
  };

  nativeBuildInputs = [pkgs.makeWrapper];

  buildInputs = [
    pkgs.jre
    pkgs.jsvc
    pkgs.curl
  ];

  # Omada Controller is a proprietary Java application distributed as a tarball
  # It contains JAR files and shell scripts that expect a specific directory layout
  unpackPhase = ''
    tar -xzf $src
    cd Omada_SDN_Controller_v${version}_linux_x64
  '';

  # No compilation needed - it's a pre-built Java application
  buildPhase = "true";

  installPhase = ''
    mkdir -p $out

    # Install read-only components to Nix store
    cp -r lib $out/
    cp -r properties $out/
    cp -r bin $out/
    cp -r data/static $out/static

    # Patch the control.sh script to work in NixOS environment
    substituteInPlace $out/bin/control.sh \
      --replace-fail 'JSVC=$(command -v jsvc)' 'JSVC=${pkgs.jsvc}/bin/jsvc' \
      --replace-fail 'CURL=$(command -v curl)' 'CURL=${pkgs.curl}/bin/curl' \
      --replace-fail 'JRE_HOME="$( readlink -f "$( which java )" | sed "s:bin/.*$::" )"' 'JRE_HOME=${pkgs.jre}'

    # Make scripts executable
    chmod +x $out/bin/*.sh
  '';

  meta = with pkgs.lib; {
    description = "TP-Link Omada Software Controller for centralized management of Omada network devices";
    longDescription = ''
      TP-Link Omada Controller is a centralized management platform for TP-Link Omada
      network devices including access points, switches, and routers. It provides a
      unified web interface for network configuration, monitoring, and management.

      This package contains v6.0.0.24 which requires Java 17 and MongoDB 3.0-8.0.
      For non-AVX CPUs, MongoDB 4.4 should be used instead of MongoDB 8.
    '';
    homepage = "https://www.tp-link.com/us/omada-sdn/";
    # Omada Controller is proprietary software
    license = licenses.unfree;
    platforms = ["x86_64-linux"];
    maintainers = [];
  };
}
