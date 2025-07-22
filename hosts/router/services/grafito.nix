{ config, lib, pkgs, ... }:
let
  grafito = pkgs.stdenv.mkDerivation rec {
    pname = "grafito";
    version = "0.10.2";
    
    src = pkgs.fetchurl {
      url = "https://github.com/ralsina/grafito/releases/download/v${version}/grafito-static-linux-amd64";
      sha256 = "0pgaw472471pyw9cgxapbcz4vjgs1i7ns4rifmxsrrs9fcj5dw24";
    };
    
    dontUnpack = true;
    
    installPhase = ''
      mkdir -p $out/bin
      cp $src $out/bin/grafito
      chmod +x $out/bin/grafito
    '';
  };
in
{
  # Grafito - Lightweight systemd journal log viewer
  systemd.services.grafito = {
    description = "Grafito - Systemd Journal Log Viewer";
    after = [ "network.target" ];
    wantedBy = [ "multi-user.target" ];
    
    serviceConfig = {
      ExecStart = "${grafito}/bin/grafito --port 8090 --bind 127.0.0.1";
      Restart = "always";
      User = "grafito";
      Group = "systemd-journal";
      # Security hardening
      PrivateTmp = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      NoNewPrivileges = true;
      ReadWritePaths = [];
    };
  };
  
  # Create grafito user with journal access
  users.users.grafito = {
    isSystemUser = true;
    group = "grafito";
    extraGroups = [ "systemd-journal" ];
  };
  
  users.groups.grafito = {};
  
  # Open port for Grafito (only on LAN interface)
  networking.firewall.interfaces.br-lan = {
    allowedTCPPorts = [ 8090 ];
  };
}