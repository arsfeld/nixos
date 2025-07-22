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
  staticHostsFile = "/etc/kea/static-hosts";
  dhcpHostsFile = "/var/lib/kea/dhcp-hosts";

  # Static IP assignments
  staticHosts = {
    router = {
      ip = routerIp;
      mac = null;
      aliases = ["router" "router.lan"];
      deviceType = "router";
    };
    storage = {
      ip = "${netConfig.prefix}.5";
      mac = "00:e0:4c:bb:00:e3";
      aliases = ["storage" "storage.lan"];
      deviceType = "server";
    };
  };

  # Kea hook script to update hosts file on lease events
  keaHostsHook = pkgs.writeScript "kea-hosts-hook" ''
    #!${pkgs.bash}/bin/bash

    # Set PATH to include necessary utilities
    export PATH="${pkgs.coreutils}/bin:${pkgs.gnugrep}/bin:${pkgs.gnused}/bin:${pkgs.util-linux}/bin:$PATH"

    # Called by Kea with environment variables:
    # LEASE4_ADDRESS - IPv4 address
    # LEASE4_HOSTNAME - Client hostname
    # KEA_LEASE4_TYPE - Event type (lease4_select, lease4_renew, lease4_release, lease4_expire)

    HOSTS_FILE="${dhcpHostsFile}"
    HOSTS_LOCK="/var/lib/kea/.hosts.lock"
    STATIC_HOSTS="${staticHostsFile}"

    (
      flock -x 200

      case "$KEA_LEASE4_TYPE" in
        lease4_select|lease4_renew)
          if [ -n "$LEASE4_HOSTNAME" ] && [ "$LEASE4_HOSTNAME" != "null" ]; then
            grep -v "^$LEASE4_ADDRESS " "$HOSTS_FILE" 2>/dev/null > "$HOSTS_FILE.tmp" || true
            mv -f "$HOSTS_FILE.tmp" "$HOSTS_FILE"
            echo "$LEASE4_ADDRESS $LEASE4_HOSTNAME $LEASE4_HOSTNAME.lan" >> "$HOSTS_FILE"
          fi
          ;;
        lease4_release|lease4_expire)
          grep -v "^$LEASE4_ADDRESS " "$HOSTS_FILE" 2>/dev/null > "$HOSTS_FILE.tmp" || true
          mv -f "$HOSTS_FILE.tmp" "$HOSTS_FILE"
          ;;
      esac

      cat "$STATIC_HOSTS" > "$HOSTS_FILE.new"
      if [ -f "$HOSTS_FILE" ]; then
        grep -v "^#" "$HOSTS_FILE" 2>/dev/null | grep -v "^$" | sort -u >> "$HOSTS_FILE.new" || true
      fi
      mv -f "$HOSTS_FILE.new" "$HOSTS_FILE"

    ) 200>"$HOSTS_LOCK"
  '';
in {
  # Export static hosts to network-metrics-exporter
  services.network-metrics-exporter.staticClients = lib.mapAttrs (name: host: {
    ip = host.ip;
    mac = host.mac;
    hostname = name;
    deviceType = host.deviceType or "unknown";
  }) (lib.filterAttrs (n: v: v.mac != null) staticHosts);
  # Disable systemd-networkd DHCP server
  systemd.network.networks."10-lan".networkConfig.DHCPServer = false;

  # Configure Kea DHCP4 server
  services.kea = {
    dhcp4 = {
      enable = true;
      settings = {
        interfaces-config = {
          interfaces = ["br-lan"];
        };

        valid-lifetime = 172800; # 48 hours - increased from 12 hours
        max-valid-lifetime = 604800; # 7 days maximum
        renew-timer = 43200; # Tell clients to renew after 12 hours
        rebind-timer = 129600; # Tell clients to rebind after 36 hours

        # Reduce decline probation period from default 24 hours to 5 minutes
        decline-probation-period = 300;

        # Lease database configuration
        lease-database = {
          type = "memfile";
          persist = true;
          name = "/var/lib/kea/kea-leases4.csv";
          lfc-interval = 3600; # Run lease file cleanup every hour to prevent duplicate buildup
          # Keep expired leases for an additional 7 days before purging
          max-row-errors = 100;
        };

        # Expired lease processing - keep expired leases in memory for tracking
        expired-leases-processing = {
          reclaim-timer-wait-time = 3600; # Wait 1 hour before reclaiming expired leases
          hold-reclaimed-time = 604800; # Hold reclaimed leases for 7 days
          max-reclaim-leases = 100; # Process up to 100 expired leases at a time
          max-reclaim-time = 250; # Spend max 250ms processing expired leases
        };

        # Hook libraries for dynamic hosts file updates and statistics
        hooks-libraries = [
          {
            library = "${pkgs.kea}/lib/kea/hooks/libdhcp_run_script.so";
            parameters = {
              name = "${keaHostsHook}";
              sync = false;
            };
          }
          {
            library = "${pkgs.kea}/lib/kea/hooks/libdhcp_stat_cmds.so";
            parameters = {};
          }
        ];

        # Enable control socket for metrics collection
        control-socket = {
          socket-type = "unix";
          socket-name = "/var/lib/kea/kea-dhcp4.sock";
        };

        subnet4 = [
          {
            id = 1;
            subnet = network;
            pools = [
              {
                pool = "${netConfig.prefix}.${toString netConfig.dhcpPool.start} - ${netConfig.prefix}.${toString netConfig.dhcpPool.end}";
              }
            ];

            option-data = [
              {
                name = "routers";
                data = routerIp;
              }
              {
                name = "domain-name-servers";
                data = routerIp;
              }
              {
                name = "domain-name";
                data = "lan";
              }
            ];

            reservations = lib.flatten (lib.mapAttrsToList (
                name: host:
                  if host.mac != null
                  then [
                    {
                      hw-address = host.mac;
                      ip-address = host.ip;
                      hostname = name;
                    }
                  ]
                  else []
              )
              staticHosts);
          }
        ];
      };
    };
  };

  # Create static hosts file
  environment.etc."kea/static-hosts".text = ''
    # Static hosts
    ${lib.concatStringsSep "\n" (lib.mapAttrsToList (
        name: host: "${host.ip} ${lib.concatStringsSep " " host.aliases}"
      )
      staticHosts)}

    # Dynamic DHCP leases
  '';

  # Update Blocky to read the hosts file
  services.blocky.settings = {
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

  # Create the initial hosts file and ensure directory exists
  systemd.tmpfiles.rules = [
    "d /var/lib/kea 0755 kea kea -"
    "C ${dhcpHostsFile} 0644 kea kea - ${staticHostsFile}"
  ];

  # Note: The hook script is already executable when created by writeScript

  # Ensure Kea doesn't use DynamicUser so paths are predictable
  systemd.services.kea-dhcp4-server = {
    serviceConfig = {
      DynamicUser = lib.mkForce false;
      User = "kea";
      Group = "kea";
    };
  };

  # Create kea user/group
  users.users.kea = {
    isSystemUser = true;
    group = "kea";
    description = "Kea DHCP daemon user";
  };

  users.groups.kea = {};
}
