{
  config,
  lib,
  pkgs,
  ...
}: {
  imports = [
    ./services/dns.nix
    ./services/dnsmasq-dhcp.nix
    ./services/vpn.nix
    ./services/upnp.nix
    ./services/natpmp.nix
    ./services/monitoring.nix
    # ./services/signoz-real.nix  # Disabled - source-based approach
    # ./services/signoz-podman.nix  # Disabled - needs troubleshooting for port exposure
    ./services/log-monitoring.nix
    ./services/caddy.nix
  ];
}
