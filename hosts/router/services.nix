{
  config,
  lib,
  pkgs,
  ...
}: {
  imports = [
    ./services/dns.nix
    ./services/vpn.nix
    ./services/upnp.nix
    ./services/monitoring.nix
  ];
}
