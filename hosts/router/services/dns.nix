{
  config,
  lib,
  pkgs,
  ...
}: let
  # Get network configuration
  netConfig = config.router.network;
  network = "${netConfig.prefix}.0/${toString netConfig.cidr}";
  routerIp = "${netConfig.prefix}.1";
in {
  # Disable systemd-resolved to free up port 53
  services.resolved.enable = false;

  # Blocky DNS server
  services.blocky = {
    enable = true;
    settings = {
      ports = {
        dns = 53;
        http = 4000;
      };
      upstreams = {
        groups = {
          default = [
            "9.9.9.9" # Quad9 DNS
            "1.1.1.1" # Cloudflare DNS
          ];
        };
      };
      # Custom DNS mappings for local network
      customDNS = {
        customTTL = "1h";
        filterUnmappedTypes = true;
        mapping = {
          # Router itself
          "router.lan" = routerIp;
          "router" = routerIp;
          # Static entries
          "storage.lan" = "${netConfig.prefix}.5";
          "storage" = "${netConfig.prefix}.5";
        };
      };
      # Conditional forwarding for special domains
      conditional = {
        mapping = {
          # Don't use conditional forwarding for .lan - Blocky will handle it via customDNS and hostsFile
          "bat-boa.ts.net" = "100.100.100.100";
          "100.in-addr.arpa" = "100.100.100.100";
          # Don't forward local reverse DNS - Blocky handles it via hostsFile
        };
      };
      blocking = {
        denylists = {
          ads = [
            "https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts"
          ];
        };
        clientGroupsBlock = {
          default = ["ads"];
        };
      };
      # Enable Prometheus metrics
      prometheus = {
        enable = true;
        path = "/metrics";
      };
    };
  };

  # Make sure Blocky starts after network is ready
  systemd.services.blocky = {
    after = ["network-online.target"];
    wants = ["network-online.target"];
  };
}
