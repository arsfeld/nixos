{ lib, buildGoModule, nodejs, nodePackages }:

let
  pname = "router-ui";
  version = "0.1.0";
  
  src = ./.;
in
buildGoModule rec {
  inherit pname version src;
  
  vendorHash = null; # Will be replaced with actual hash after first build
  
  # Build-time dependencies
  nativeBuildInputs = [
    nodejs
    nodePackages.npm
  ];
  
  # Build the web assets before building the Go binary
  preBuild = ''
    # Install npm dependencies and build web assets
    cd web
    npm install
    npm run build
    cd ..
  '';
  
  # Install the binary and web assets
  postInstall = ''
    # Create directories
    mkdir -p $out/share/router-ui/web
    
    # Copy web assets
    cp -r web/static $out/share/router-ui/web/
    cp -r web/templates $out/share/router-ui/web/
    
    # Create wrapper script that sets the correct paths
    mv $out/bin/router_ui $out/bin/.router_ui-wrapped
    cat > $out/bin/router_ui <<EOF
    #!/bin/sh
    export ROUTER_UI_STATIC_DIR="$out/share/router-ui/web/static"
    export ROUTER_UI_TEMPLATES_DIR="$out/share/router-ui/web/templates"
    exec $out/bin/.router_ui-wrapped "\$@"
    EOF
    chmod +x $out/bin/router_ui
  '';
  
  meta = with lib; {
    description = "Web interface for router management with VPN client control";
    homepage = "https://github.com/arosenfeld/nixos-config";
    license = licenses.mit;
    maintainers = with maintainers; [ ];
    platforms = platforms.linux;
  };
}