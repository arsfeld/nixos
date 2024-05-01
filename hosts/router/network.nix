{
  config,
  lib,
  pkgs,
  ...
}: let
  settings = import ./settings.nix;
in {
  # Allow NAT stuff ...
  boot.kernel.sysctl = {
    "net.ipv4.conf.all.forwarding" = true;
    "net.ipv6.conf.all.forwarding" = true;

    # source: https://github.com/mdlayher/homelab/blob/master/nixos/routnerr-2/configuration.nix#L52
    # By default, not automatically configure any IPv6 addresses.
    "net.ipv6.conf.all.accept_ra" = 0;
    "net.ipv6.conf.all.autoconf" = 0;
    "net.ipv6.conf.all.use_tempaddr" = 0;

    # On WAN, allow IPv6 autoconfiguration and tempory address use.
    "net.ipv6.conf.${settings.wanInterface}.accept_ra" = 2;
    "net.ipv6.conf.${settings.wanInterface}.autoconf" = 1;
  };

  networking = {
    hostName = "router";
    useNetworkd = true;
    useDHCP = false;

    # No local firewall.
    nat.enable = false;
    firewall.enable = false;

    # Use the nftables firewall instead of the base nixos scripted rules.
    # This flake provides a similar utility to the base nixos scripting.
    # https://github.com/thelegy/nixos-nftables-firewall/tree/main
    nftables = {
      enable = true;
      stopRuleset = "";
      chains.prerouting.plex.rules = [
        "tcp dport { 32400 } dnat ip to 192.168.10.5"
      ];
      firewall = {
        enable = true;
        zones = {
          lan.interfaces = ["br-lan"];
          wan.interfaces = ["${settings.wanInterface}"];
          trusted.interfaces = ["tailscale0"];
        };
        rules = {
          lan = {
            from = ["lan"];
            to = ["fw"];
            verdict = "accept";
          };
          outbound = {
            from = ["lan"];
            to = ["lan" "wan"];
            verdict = "accept";
          };
          trusted1 = {
            from = ["trusted"];
            to = ["all"];
            verdict = "accept";
          };
          trusted2 = {
            from = ["all"];
            to = ["trusted"];
            verdict = "accept";
          };
          plex = {
            from = ["all"];
            to = ["wan"];
            allowedTCPPorts = [32400];
            verdict = "accept";
          };
          nat = {
            from = ["lan"];
            to = ["wan"];
            masquerade = true;
          };
        };
      };
    };
  };

  systemd.network = {
    wait-online.anyInterface = true;
    netdevs = {
      # Create the bridge interface
      "20-br-lan" = {
        netdevConfig = {
          Kind = "bridge";
          Name = "br-lan";
        };
      };
    };
    networks = {
      # Connect the bridge ports to the bridge
      "30-lan0" = {
        matchConfig.Name = lib.elemAt settings.lanInterfaces 0;
        networkConfig = {
          Bridge = "br-lan";
          ConfigureWithoutCarrier = true;
        };
        linkConfig.RequiredForOnline = "enslaved";
      };
      "30-lan1" = {
        matchConfig.Name = lib.elemAt settings.lanInterfaces 1;
        networkConfig = {
          Bridge = "br-lan";
          ConfigureWithoutCarrier = true;
        };
        linkConfig.RequiredForOnline = "enslaved";
      };
      "30-lan2" = {
        matchConfig.Name = lib.elemAt settings.lanInterfaces 2;
        networkConfig = {
          Bridge = "br-lan";
          ConfigureWithoutCarrier = true;
        };
        linkConfig.RequiredForOnline = "enslaved";
      };
      # Configure the bridge for its desired function
      "40-br-lan" = {
        matchConfig.Name = "br-lan";
        bridgeConfig = {};
        address = [
          "192.168.10.1/24"
        ];
        networkConfig = {
          ConfigureWithoutCarrier = true;
        };
        # Don't wait for it as it also would wait for wlan and DFS which takes around 5 min
        linkConfig.RequiredForOnline = "no";
      };
      "10-wan" = {
        matchConfig.Name = "${settings.wanInterface}";
        networkConfig = {
          # start a DHCP Client for IPv4 Addressing/Routing
          DHCP = "ipv4";
          # accept Router Advertisements for Stateless IPv6 Autoconfiguraton (SLAAC)
          IPv6AcceptRA = true;
          DNSOverTLS = true;
          DNSSEC = true;
          IPv6PrivacyExtensions = false;
          IPForward = true;
        };
        cakeConfig = {
          Bandwidth = "250M";
          CompensationMode = "ptm";
          OverheadBytes = 8;
        };
        # make routing on this interface a dependency for network-online.target
        linkConfig.RequiredForOnline = "routable";
      };
    };
  };

  services.resolved.enable = false;

  virtualisation.libvirtd = {
    enable = true;
  };

  services.adguardhome = {
    enable = true;
    settings = {
      users = [
        {
          name = "admin";
          password = "$2a$10$ZqHeXubJoB7II0u/39Byiu4McdkjCoqurctIlMikm4kyILQvEevEO";
        }
      ];
      bind_port = 3000;
      dns = {
        bind_hosts = ["0.0.0.0"];
        port = 53;
      };
      dhcp = {
        enabled = true;
        interface_name = "br-lan";
        dhcpv4 = {
          gateway_ip = "192.168.10.1";
          subnet_mask = "255.255.255.0";
          range_start = "192.168.10.50";
          range_end = "192.168.10.250";
          lease_duration = 86400;
        };
        dhcpv6 = {
          range_start = "2001::1";
          lease_duration = 86400;
        };
      };
    };
  };

  # This is not really secure, but some games need it.
  services.miniupnpd-nftables = {
    enable = true;
    externalInterface = "${settings.wanInterface}";
    internalIPs = ["br-lan"];
    natpmp = true;
  };

  services.tailscale = {
    enable = true;
  };

  services.avahi = {
    enable = true;
    nssmdns4 = true;
    interfaces = ["br-lan" "tailscale0"];
  };

  services.dnsmasq = {
    enable = false;
    settings = {
      # upstream DNS servers
      server = ["9.9.9.9" "8.8.8.8" "1.1.1.1"];
      # sensible behaviours
      domain-needed = true;
      bogus-priv = true;
      no-resolv = true;

      port = 53;

      dhcp-range = ["br-lan,192.168.10.50,192.168.10.254,24h"];
      interface = "br-lan";
      dhcp-host = "192.168.10.1";

      # local domains
      local = "/lan/";
      domain = "lan";
      expand-hosts = true;

      # don't use /etc/hosts as this would advertise surfer as localhost
      no-hosts = true;
      address = "/router.lan/192.168.10.1";
    };
  };

  # The service irqbalance is useful as it assigns certain IRQ calls to specific CPUs instead of letting the first CPU core to handle everything. This is supposed to increase performance by hitting CPU cache more often.
  services.irqbalance.enable = true;
}
