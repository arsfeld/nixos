# IPv6 router test
# Tests IPv6 connectivity, prefix delegation, SLAAC, and dual-stack operation
{
  self,
  inputs,
}: {
  lib,
  pkgs,
  ...
}: {
  name = "router-ipv6-test";

  nodes = {
    # ISP simulator providing IPv6 prefix delegation
    isp = {
      config,
      pkgs,
      ...
    }: {
      virtualisation.vlans = [1];

      networking = {
        useDHCP = false;
        useNetworkd = true;
        firewall.enable = false;
      };

      # Enable IPv6 forwarding
      boot.kernel.sysctl = {
        "net.ipv6.conf.all.forwarding" = 1;
      };

      systemd.network = {
        enable = true;
        networks = {
          "10-wan" = {
            matchConfig.Name = "eth1";
            address = [
              "192.168.100.1/24"
              "2001:db8:ffff::1/64"
            ];
            networkConfig = {
              DHCPServer = true;
              IPv6SendRA = true;
              IPv6PrefixDelegation = "yes";
            };
            dhcpServerConfig = {
              PoolOffset = 10;
              PoolSize = 50;
              EmitDNS = true;
              DNS = "192.168.100.1";
              EmitRouter = true;
            };
            # Advertise IPv6 prefix and delegate a /56
            ipv6SendRAConfig = {
              RouterLifetimeSec = 1800;
              EmitDNS = true;
              DNS = "2001:db8:ffff::1";
            };
            ipv6Prefixes = [{
              Prefix = "2001:db8:ffff::/64";
              PreferredLifetimeSec = 3600;
              ValidLifetimeSec = 7200;
            }];
            # Delegate a /56 prefix to the router
            dhcpPrefixDelegationConfig = {
              UplinkInterface = ":self";
              SubnetId = "0x01";
              Announce = true;
            };
          };
        };
      };

      # DNS server for IPv6
      services.dnsmasq = {
        enable = true;
        settings = {
          interface = "eth1";
          bind-interfaces = true;
          # Provide DNS for both IPv4 and IPv6
          server = ["1.1.1.1" "2606:4700:4700::1111"];
          # IPv6 specific settings
          enable-ra = true;
          dhcp-range = "::,constructor:eth1,ra-stateless,ra-names";
        };
      };
    };

    # Router with IPv6 enabled (modified version of production config)
    router = {
      config,
      pkgs,
      ...
    }: {
      imports = [
        "${self}/hosts/router/configuration.nix"
      ];

      virtualisation.vlans = [1 2 3 4];

      # Override router configuration for testing
      router.interfaces = {
        wan = "eth1";
        lan1 = "eth2";
        lan2 = "eth3";
        lan3 = "eth4";
      };

      # Enable IPv6 (override production settings)
      boot.kernel.sysctl = lib.mkForce {
        "net.ipv4.ip_forward" = 1;
        "net.ipv6.conf.all.forwarding" = 1;
        "net.ipv6.conf.default.forwarding" = 1;
      };

      # Update network configuration for IPv6
      systemd.network.networks = {
        "10-wan" = lib.mkForce {
          matchConfig.Name = "eth1";
          networkConfig = {
            DHCP = "yes";
            IPv6AcceptRA = true;
            IPv6PrivacyExtensions = false;
            # Request prefix delegation
            DHCPPrefixDelegation = true;
          };
          dhcpV6Config = {
            PrefixDelegationHint = "::/56";
          };
          ipv6AcceptRAConfig = {
            DHCPv6Client = "yes";
          };
          linkConfig.RequiredForOnline = "routable";
        };

        "40-br-lan" = lib.mkForce {
          matchConfig.Name = "br-lan";
          address = ["10.1.1.1/24"];
          networkConfig = {
            IPv4Forwarding = true;
            IPv6Forwarding = true;
            IPv6AcceptRA = false;
            IPv6SendRA = true;
            DHCPPrefixDelegation = true;
            # Assign IPv6 from delegated prefix
            IPv6DuplicateAddressDetection = 1;
          };
          # Configure Router Advertisements
          ipv6SendRAConfig = {
            RouterLifetimeSec = 1800;
            EmitDNS = true;
            DNS = "_link_local";
          };
          # Use delegated prefix for SLAAC
          ipv6Prefixes = [{
            Prefix = "::/64";
            PreferredLifetimeSec = 3600;
            ValidLifetimeSec = 7200;
          }];
          linkConfig.RequiredForOnline = "no";
        };
      };

      # Update nftables for IPv6
      networking.nftables.ruleset = lib.mkForce ''
        table inet filter {
          chain input {
            type filter hook input priority 0; policy drop;

            ct state established,related accept
            iif lo accept
            
            # IPv4 ICMP
            ip protocol icmp accept
            
            # IPv6 ICMPv6 (essential for IPv6)
            ip6 nexthdr icmpv6 icmpv6 type { 
              destination-unreachable, 
              packet-too-big, 
              time-exceeded, 
              parameter-problem, 
              echo-request, 
              echo-reply,
              nd-router-solicit,
              nd-router-advert,
              nd-neighbor-solicit,
              nd-neighbor-advert,
              mld-listener-query,
              mld-listener-report,
              mld-listener-reduction
            } accept

            # Allow SSH from LAN
            iifname "br-lan" tcp dport 22 accept

            # Allow DNS, DHCP from LAN
            iifname "br-lan" udp dport { 53, 67, 547 } accept
            iifname "br-lan" tcp dport 53 accept

            # DHCPv6 client on WAN
            iifname "eth1" udp sport 547 udp dport 546 accept
          }

          chain forward {
            type filter hook forward priority 0; policy drop;

            ct state established,related accept

            # Allow LAN to WAN (both IPv4 and IPv6)
            iifname "br-lan" oifname "eth1" accept

            # Allow LAN to LAN
            iifname "br-lan" oifname "br-lan" accept
          }

          chain output {
            type filter hook output priority 0; policy accept;
          }
        }
        
        table ip nat {
          chain postrouting {
            type nat hook postrouting priority 100;
            oifname "eth1" masquerade
          }
        }
      '';

      # Update DNS for IPv6
      services.blocky.settings = lib.mkForce {
        ports = {
          dns = 53;
          http = 4000;
        };
        connectIPVersion = "dual";
        upstreams = {
          groups = {
            default = [
              "192.168.100.1"
              "2001:db8:ffff::1"
              "1.1.1.1"
              "2606:4700:4700::1111"
            ];
          };
        };
        customDNS = {
          customTTL = "1h";
          filterUnmappedTypes = true;
          mapping = {
            "router.lan" = "10.1.1.1";
            "router" = "10.1.1.1";
          };
        };
      };
    };

    # Client to test dual-stack connectivity
    client = {
      config,
      pkgs,
      ...
    }: {
      virtualisation.vlans = [2];

      networking = {
        useDHCP = false;
        useNetworkd = true;
        firewall.enable = false;
      };

      systemd.network = {
        enable = true;
        networks = {
          "30-lan" = {
            matchConfig.Name = "eth1";
            networkConfig = {
              DHCP = "yes";
              IPv6AcceptRA = true;
              IPv6PrivacyExtensions = false;
            };
          };
        };
      };

      environment.systemPackages = with pkgs; [
        dnsutils
        iproute2
        iputils
        curl
      ];
    };
  };

  testScript = ''
    start_all()

    # Wait for all machines to be ready
    isp.wait_for_unit("multi-user.target")
    router.wait_for_unit("multi-user.target")
    client.wait_for_unit("multi-user.target")

    # Wait for network to be ready
    isp.wait_for_unit("systemd-networkd.service")
    router.wait_for_unit("systemd-networkd.service")
    client.wait_for_unit("systemd-networkd.service")

    # Give time for IPv6 configuration
    router.sleep(10)
    client.sleep(10)

    with subtest("ISP provides IPv6 connectivity"):
        isp.succeed("ip -6 addr show eth1 | grep 2001:db8:ffff::1")
        isp.succeed("ping -6 -c 1 2001:db8:ffff::1")

    with subtest("Router receives IPv6 prefix delegation"):
        # Router should have IPv6 on WAN
        router.wait_until_succeeds("ip -6 addr show eth1 | grep 2001:db8", timeout=30)
        
        # Router should have delegated prefix on LAN
        router.wait_until_succeeds("ip -6 addr show br-lan | grep 2001:db8", timeout=30)
        
        # Check IPv6 routing is enabled
        router.succeed("sysctl net.ipv6.conf.all.forwarding | grep 1")

    with subtest("Client receives IPv6 via SLAAC"):
        # Client should get IPv6 address via SLAAC
        client.wait_until_succeeds("ip -6 addr show eth1 | grep 2001:db8", timeout=30)
        
        # Client should have default route via router
        client.wait_until_succeeds("ip -6 route | grep default", timeout=30)
        
        # Verify client got both IPv4 and IPv6
        client.succeed("ip addr show eth1 | grep 'inet '")
        client.succeed("ip addr show eth1 | grep 'inet6 2001:db8'")

    with subtest("IPv6 connectivity through router"):
        # Client can ping router's IPv6 address
        router_ipv6 = router.succeed("ip -6 addr show br-lan | grep 2001:db8 | grep -v fe80 | awk '{print $2}' | cut -d/ -f1 | head -1").strip()
        client.succeed(f"ping -6 -c 1 {router_ipv6}")
        
        # Client can ping ISP's IPv6
        client.succeed("ping -6 -c 1 2001:db8:ffff::1")

    with subtest("DNS resolution works for IPv6"):
        # DNS should resolve both A and AAAA records
        client.succeed("host google.com 10.1.1.1 | grep 'has address'")
        client.succeed("host google.com 10.1.1.1 | grep 'has IPv6 address'")

    with subtest("Dual-stack operation"):
        # Verify both IPv4 and IPv6 work simultaneously
        client.succeed("ping -4 -c 1 10.1.1.1")
        client.succeed(f"ping -6 -c 1 {router_ipv6}")
        
        # Verify both protocols can access external addresses
        client.succeed("ping -4 -c 1 192.168.100.1")
        client.succeed("ping -6 -c 1 2001:db8:ffff::1")

    with subtest("IPv6 firewall allows essential ICMPv6"):
        # Neighbor discovery should work
        client.succeed(f"ping -6 -c 1 {router_ipv6}")
        
        # Path MTU discovery
        client.succeed(f"ping -6 -c 1 -s 1400 {router_ipv6}")

    with subtest("Router advertisements work correctly"):
        # Client should see router advertisements
        client.succeed("ip -6 route | grep ra-")
        
        # Check RA flags
        output = client.succeed("rdisc6 eth1 || true")
        print(f"Router advertisement info: {output}")
  '';
}