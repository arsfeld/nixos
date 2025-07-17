{
  config,
  lib,
  pkgs,
  ...
}: let
  netConfig = config.router.network;
  network = "${netConfig.prefix}.0/${toString netConfig.cidr}";
  routerIp = "${netConfig.prefix}.1";
in {
  # Disable systemd-networkd DHCP server
  systemd.network.networks."10-lan".networkConfig.DHCPServer = false;
  
  # Configure dnsmasq as DHCP server only
  services.dnsmasq = {
    enable = true;
    settings = {
      # Disable DNS server functionality - we're using Blocky for DNS
      port = 0;  # Disables DNS
      
      # DHCP configuration
      interface = "br-lan";
      bind-interfaces = true;
      
      # DHCP range
      dhcp-range = "${netConfig.prefix}.100,${netConfig.prefix}.149,12h";
      
      # DHCP options
      dhcp-option = [
        "option:router,${routerIp}"
        "option:dns-server,${routerIp}"  # Points to Blocky on the router
      ];
      
      # Static DHCP leases
      dhcp-host = [
        "00:e0:4c:bb:00:e3,storage,${netConfig.prefix}.5"
        # Add more static leases here as needed
        # "aa:bb:cc:dd:ee:ff,laptop,${netConfig.prefix}.10"
      ];
      
      # Domain configuration
      domain = "lan";
      local = "/lan/";
      expand-hosts = true;
      
      # Important: Generate /etc/hosts entries from DHCP leases
      # This allows other services to resolve DHCP hostnames
      dhcp-leasefile = "/var/lib/dnsmasq/dnsmasq.leases";
      
      # Log DHCP transactions for debugging
      log-dhcp = true;
      
      # Don't use /etc/hosts
      no-hosts = true;
      
      # Create a hosts file that Blocky can read
      addn-hosts = "/var/lib/dnsmasq/dhcp-hosts";
    };
  };
  
  # Service to sync dnsmasq DHCP leases to a hosts file for Blocky
  systemd.services.dnsmasq-hosts-sync = {
    description = "Sync dnsmasq DHCP leases to hosts file";
    after = ["dnsmasq.service"];
    wantedBy = ["multi-user.target"];
    
    script = ''
      #!${pkgs.bash}/bin/bash
      set -e
      
      LEASE_FILE="/var/lib/dnsmasq/dnsmasq.leases"
      HOSTS_FILE="/var/lib/dnsmasq/dhcp-hosts"
      HOSTS_TMP="/var/lib/dnsmasq/dhcp-hosts.tmp"
      
      mkdir -p /var/lib/dnsmasq
      
      # Initialize hosts file with static entries
      cat > "$HOSTS_TMP" << EOF
      # Static hosts
      ${routerIp} router router.lan
      ${netConfig.prefix}.5 storage storage.lan
      EOF
      
      while true; do
        if [ -f "$LEASE_FILE" ]; then
          # Parse dnsmasq lease file
          # Format: timestamp mac ip hostname client-id
          {
            cat "$HOSTS_TMP"
            echo ""
            echo "# Dynamic DHCP leases"
            ${pkgs.gawk}/bin/awk '{
              if ($4 != "*" && $4 != "") {
                print $3 " " $4 " " $4 ".lan"
              }
            }' "$LEASE_FILE" | sort -u
          } > "$HOSTS_FILE.new"
          
          # Atomic update
          mv "$HOSTS_FILE.new" "$HOSTS_FILE"
          
          # Blocky will automatically reload the hosts file based on refreshPeriod
        fi
        
        sleep 30
      done
    '';
    
    serviceConfig = {
      Type = "simple";
      Restart = "always";
      RestartSec = "10s";
    };
  };
  
  # Update Blocky to read the hosts file
  services.blocky.settings = {
    # Add hosts file as additional source at the top level
    hostsFile = {
      sources = [
        "/var/lib/dnsmasq/dhcp-hosts"
      ];
      hostsTTL = "30s";
      filterLoopback = false;
      loading = {
        refreshPeriod = "30s";
      };
    };
    
    # Custom DNS mappings for static entries
    customDNS = {
      customTTL = "1h";
      filterUnmappedTypes = true;
      mapping = {
        # Static mappings remain here
        "router.lan" = routerIp;
        "router" = routerIp;
        "storage.lan" = "${netConfig.prefix}.5";
        "storage" = "${netConfig.prefix}.5";
      };
    };
  };
  
  # Make sure dnsmasq starts after network is ready
  systemd.services.dnsmasq = {
    after = ["network-online.target" "sys-subsystem-net-devices-br\\x2dlan.device"];
    wants = ["network-online.target"];
  };
  
  # Create required directories
  systemd.tmpfiles.rules = [
    "d /var/lib/dnsmasq 0755 root root -"
  ];
}