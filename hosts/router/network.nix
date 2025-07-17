{
  config,
  lib,
  pkgs,
  ...
}: let
  # Get interface names from configuration
  interfaces = config.router.interfaces;

  # Network configuration
  netConfig = config.router.network;

  # Computed values
  network = "${netConfig.prefix}.0/${toString netConfig.cidr}";
  routerIp = "${netConfig.prefix}.1";
  dhcpStart = 100;
  dhcpSize = 50;
in {
  options.router = {
    interfaces = lib.mkOption {
      type = lib.types.attrs;
      description = "Network interface names";
    };

    network = lib.mkOption {
      type = lib.types.attrs;
      default = {
        prefix = "192.168.10";
        cidr = 24;
      };
      description = "Network configuration for LAN";
    };
  };

  config = {
    # nftables firewall configuration
    networking.nftables = {
      enable = true;
      ruleset = ''
        table inet filter {
          chain input {
            type filter hook input priority 0; policy drop;

            ct state established,related accept
            iif lo accept
            ip protocol icmp accept

            # Allow SSH from LAN bridge
            iifname "br-lan" tcp dport 22 accept

            # Allow DNS, DHCP from LAN bridge
            iifname "br-lan" udp dport { 53, 67 } accept

            # Allow UPnP from LAN bridge
            iifname "br-lan" tcp dport 1024-65535 accept  # miniupnpd HTTP (uses dynamic port)
            iifname "br-lan" udp dport { 1900, 5351 } accept   # SSDP and NAT-PMP

            # Allow Tailscale traffic
            iifname "tailscale0" accept
            udp dport 41641 accept  # Tailscale WireGuard port
          }

          chain forward {
            type filter hook forward priority 0; policy drop;

            # Jump to client traffic accounting (before conntrack to count all traffic)
            jump CLIENT_TRAFFIC

            ct state established,related accept

            # Allow LAN to WAN
            iifname "br-lan" oifname "${interfaces.wan}" accept

            # Allow LAN to LAN (between bridged interfaces)
            iifname "br-lan" oifname "br-lan" accept

            # Allow Tailscale forwarding
            iifname "tailscale0" accept
            oifname "tailscale0" accept

            # Allow LAN to Tailscale
            iifname "br-lan" oifname "tailscale0" accept
            iifname "tailscale0" oifname "br-lan" accept

            # Jump to miniupnpd chain for port forwards
            jump MINIUPNPD
          }

          chain output {
            type filter hook output priority 0; policy accept;
          }

          # Chain for miniupnpd port forwards
          chain MINIUPNPD {
          }

          # Chain for per-client traffic accounting
          chain CLIENT_TRAFFIC {
            # Traffic accounting rules will be added here dynamically
          }
        }

        table ip nat {
          chain prerouting {
            type nat hook prerouting priority -100;
            jump MINIUPNPD
          }

          chain postrouting {
            type nat hook postrouting priority 100;
            oifname "${interfaces.wan}" masquerade
            oifname "tailscale0" masquerade
          }

          # Chain for miniupnpd DNAT rules
          chain MINIUPNPD {
          }
        }
      '';
    };

    # SystemD network configuration
    systemd.network = {
      enable = true;

      # Create bridge device
      netdevs = {
        "20-br-lan" = {
          netdevConfig = {
            Kind = "bridge";
            Name = "br-lan";
          };
        };
      };

      networks = {
        # WAN interface (adjust interface name as needed)
        "10-wan" = {
          matchConfig.Name = interfaces.wan;
          networkConfig = {
            DHCP = "yes";
            IPv6AcceptRA = false;
          };
          linkConfig.RequiredForOnline = "routable";
        };

        # LAN interfaces connected to bridge
        "30-lan1" = {
          matchConfig.Name = interfaces.lan1;
          networkConfig = {
            Bridge = "br-lan";
          };
          linkConfig.RequiredForOnline = "enslaved";
        };

        "30-lan2" = {
          matchConfig.Name = interfaces.lan2;
          networkConfig = {
            Bridge = "br-lan";
          };
          linkConfig.RequiredForOnline = "enslaved";
        };

        "30-lan3" = {
          matchConfig.Name = interfaces.lan3;
          networkConfig = {
            Bridge = "br-lan";
          };
          linkConfig.RequiredForOnline = "enslaved";
        };

        # Configure the bridge
        "40-br-lan" = {
          matchConfig.Name = "br-lan";
          address = ["${routerIp}/${toString netConfig.cidr}"];
          networkConfig = {
            DHCPServer = true;
            IPv4Forwarding = true;
            IPv6Forwarding = false;
          };
          dhcpServerConfig = {
            PoolOffset = dhcpStart;
            PoolSize = dhcpSize;
            EmitDNS = true;
            DNS = routerIp; # Blocky DNS server
            EmitRouter = true;
          };
          dhcpServerStaticLeases = [
            {
              # Storage server static IP
              Address = "${netConfig.prefix}.5";
              MACAddress = "00:e0:4c:bb:00:e3";
            }
          ];
          linkConfig.RequiredForOnline = "no";
        };
      };
    };
  };
}
