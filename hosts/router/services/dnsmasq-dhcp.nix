{
  config,
  lib,
  pkgs,
  ...
}: let
  netConfig = config.router.network;
  network = "${netConfig.prefix}.0/${toString netConfig.cidr}";
  routerIp = "${netConfig.prefix}.1";

  # File paths
  staticHostsFile = "/etc/dnsmasq/static-hosts"; # Contains static entries + dynamic header
  dhcpHostsFile = "/var/lib/dnsmasq/dhcp-hosts";

  # Static IP assignments
  staticHosts = {
    router = {
      ip = routerIp;
      mac = null; # Router doesn't need MAC
      aliases = ["router" "router.lan"];
    };
    storage = {
      ip = "${netConfig.prefix}.5";
      mac = "00:e0:4c:bb:00:e3";
      aliases = ["storage" "storage.lan"];
    };
    # Add more static hosts here as needed
    # laptop = {
    #   ip = "${netConfig.prefix}.10";
    #   mac = "aa:bb:cc:dd:ee:ff";
    #   aliases = ["laptop" "laptop.lan"];
    # };
  };
in {
  # Disable systemd-networkd DHCP server
  systemd.network.networks."10-lan".networkConfig.DHCPServer = false;

  # Configure dnsmasq as DHCP server only
  services.dnsmasq = {
    enable = true;
    settings = {
      # Disable DNS server functionality - we're using Blocky for DNS
      port = 0; # Disables DNS

      # DHCP configuration
      interface = "br-lan";
      bind-interfaces = true;

      # DHCP range
      dhcp-range = "${netConfig.prefix}.100,${netConfig.prefix}.149,12h";

      # DHCP options
      dhcp-option = [
        "option:router,${routerIp}"
        "option:dns-server,${routerIp}" # Points to Blocky on the router
      ];

      # Static DHCP leases from our centralized list
      dhcp-host = lib.flatten (lib.mapAttrsToList (
          name: host:
            if host.mac != null
            then "${host.mac},${name},${host.ip}"
            else []
        )
        staticHosts);

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

      # Use dhcp-script to update hosts file on DHCP events
      dhcp-script = let
        dhcpScript = pkgs.writeScript "dnsmasq-dhcp-script" ''
          #!${pkgs.bash}/bin/bash
          # Called by dnsmasq with arguments:
          # $1 = add/del/old
          # $2 = MAC address
          # $3 = IP address
          # $4 = hostname (if provided by client)

          HOSTS_FILE="${dhcpHostsFile}"
          HOSTS_LOCK="/var/lib/dnsmasq/.hosts.lock"
          STATIC_HOSTS="${staticHostsFile}"

          # Use flock for atomic updates
          (
            flock -x 200

            case "$1" in
              add|old)
                if [ -n "$4" ] && [ "$4" != "*" ]; then
                  # Remove any existing entry for this IP
                  grep -v "^$3 " "$HOSTS_FILE" 2>/dev/null > "$HOSTS_FILE.tmp" || true
                  mv -f "$HOSTS_FILE.tmp" "$HOSTS_FILE"

                  # Add new entry
                  echo "$3 $4 $4.lan" >> "$HOSTS_FILE"
                fi
                ;;
              del)
                # Remove entry for this IP
                grep -v "^$3 " "$HOSTS_FILE" 2>/dev/null > "$HOSTS_FILE.tmp" || true
                mv -f "$HOSTS_FILE.tmp" "$HOSTS_FILE"
                ;;
            esac

            # Regenerate complete hosts file
            # Copy static hosts (which already includes the "# Dynamic DHCP leases" header)
            cat "$STATIC_HOSTS" > "$HOSTS_FILE.new"

            # Add all current dynamic entries (skip comments and empty lines)
            if [ -f "$HOSTS_FILE" ]; then
              grep -v "^#" "$HOSTS_FILE" 2>/dev/null | grep -v "^$" | sort -u >> "$HOSTS_FILE.new" || true
            fi

            # Atomic replace
            mv -f "$HOSTS_FILE.new" "$HOSTS_FILE"

          ) 200>"$HOSTS_LOCK"
        '';
      in "${dhcpScript}";
    };
  };

  # Create static hosts file with dynamic header
  environment.etc."dnsmasq/static-hosts".text = ''
    # Static hosts
    ${lib.concatStringsSep "\n" (lib.mapAttrsToList (
        name: host: "${host.ip} ${lib.concatStringsSep " " host.aliases}"
      )
      staticHosts)}

    # Dynamic DHCP leases
  '';

  # Update Blocky to read the hosts file
  services.blocky.settings = {
    # Add hosts file as additional source at the top level
    hostsFile = {
      sources = [
        dhcpHostsFile
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
      mapping = lib.mkMerge (lib.flatten (lib.mapAttrsToList (
          name: host:
            map (alias: {
              "${alias}" = host.ip;
            })
            host.aliases
        )
        staticHosts));
    };
  };

  # Make sure dnsmasq starts after network is ready
  systemd.services.dnsmasq = {
    after = ["network-online.target" "sys-subsystem-net-devices-br\\x2dlan.device"];
    wants = ["network-online.target"];
  };

  # Create required directories and files
  systemd.tmpfiles.rules = [
    "d /var/lib/dnsmasq 0755 dnsmasq root -"
    # Create dhcp-hosts file if it doesn't exist, copying from static hosts
    "C ${dhcpHostsFile} 0644 dnsmasq root - ${staticHostsFile}"
  ];
}
