{
  config,
  lib,
  pkgs,
  ...
}: {
  imports = [
    ./services/dns.nix
    ./services/kea-dhcp.nix
    ./services/vpn.nix
    ./services/upnp.nix
    ./services/natpmp.nix
    ./services/monitoring.nix
    ./services/log-monitoring.nix
    ./services/grafito.nix
    ./services/caddy.nix
    ../../packages/network-metrics-exporter/module.nix
  ];
}
