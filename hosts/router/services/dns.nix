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
      # Bootstrap DNS to resolve blocklist URLs during startup
      bootstrapDns = [
        {
          upstream = "9.9.9.9";
          ips = ["9.9.9.9"];
        }
        {
          upstream = "1.1.1.1";
          ips = ["1.1.1.1"];
        }
      ];
      # Force IPv4 only for downloads
      connectIPVersion = "v4";
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
            "https://someonewhocares.org/hosts/zero/hosts"
            "https://raw.githubusercontent.com/bigdargon/hostsVN/master/hosts"
          ];
          tracking = [
            "https://raw.githubusercontent.com/crazy-max/WindowsSpyBlocker/master/data/hosts/spy.txt"
            "https://hostfiles.frogeye.fr/firstparty-trackers-hosts.txt"
            "https://raw.githubusercontent.com/neodevpro/neodevhost/master/host"
          ];
          telemetry = [
            "https://raw.githubusercontent.com/crazy-max/WindowsSpyBlocker/master/data/hosts/spy.txt"
            "https://raw.githubusercontent.com/Perflyst/PiHoleBlocklist/master/android-tracking.txt"
            "https://raw.githubusercontent.com/Perflyst/PiHoleBlocklist/master/AmazonFireTV.txt"
            "https://raw.githubusercontent.com/0Zinc/easylists-for-pihole/master/easyprivacy.txt"
            "https://v.firebog.net/hosts/Prigent-Ads.txt"
          ];
          malware = [
            "https://urlhaus.abuse.ch/downloads/hostfile/"
            "https://gitlab.com/quidsup/notrack-blocklists/raw/master/notrack-malware.txt"
          ];
        };
        clientGroupsBlock = {
          default = ["ads" "tracking" "telemetry" "malware"];
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
    after = ["network-online.target" "nftables.service"];
    wants = ["network-online.target"];
    # Add a small delay to ensure network is fully ready
    serviceConfig = {
      ExecStartPre = "${pkgs.coreutils}/bin/sleep 5";
    };
  };
}
