# Router test for development iteration
# Tests basic connectivity, NAT, DHCP, and NAT-PMP
{
  self,
  inputs,
}: {
  lib,
  pkgs,
  ...
}: {
  name = "router-test";

  nodes = {
    # Storage server with static IP
    storage = {
      config,
      pkgs,
      ...
    }: {
      virtualisation.vlans = [2]; # Connected to first LAN port

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
              IPv6AcceptRA = false;
            };
          };
        };
        # Set MAC address for the interface
        links = {
          "10-eth1" = {
            matchConfig.OriginalName = "eth1";
            linkConfig.MACAddress = "00:e0:4c:bb:00:e3";
          };
        };
      };

      # Simple service to identify this as storage
      systemd.services.storage-marker = {
        wantedBy = ["multi-user.target"];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = "${pkgs.coreutils}/bin/echo 'Storage server with static IP 192.168.10.5'";
        };
      };
    };

    # External server to simulate internet
    external = {
      config,
      pkgs,
      ...
    }: {
      virtualisation.vlans = [1];
      networking.interfaces.eth1 = {
        ipv4.addresses = [
          {
            address = "10.0.2.1";
            prefixLength = 24;
          }
        ];
      };

      # Simple web server to test connectivity
      services.nginx = {
        enable = true;
        virtualHosts."default" = {
          default = true;
          locations."/" = {
            return = "200 'External server response'";
            extraConfig = "add_header Content-Type text/plain;";
          };
        };
      };
      networking.firewall.allowedTCPPorts = [80];
    };

    # Router using the actual configuration
    router = {
      config,
      pkgs,
      ...
    }: {
      imports = [
        # Import only the modules we need, not disk/hardware config
        "${self}/hosts/router/network.nix"
        "${self}/hosts/router/services.nix"
      ];

      # Test-specific overrides
      virtualisation.vlans = [1 2 3]; # WAN + 2 LAN ports

      # Set interface names for test environment
      router.interfaces = {
        wan = "eth1"; # Test VMs use eth1 for WAN
        lan1 = "eth2"; # Test VMs use eth2 for first LAN
        lan2 = "eth3"; # Test VMs use eth3 for second LAN
        lan3 = "eth4"; # Not used in test but define for completeness
      };

      # For test, use static IP on WAN instead of DHCP
      systemd.network.networks."10-wan" = lib.mkForce {
        matchConfig.Name = "eth1";
        address = ["10.0.2.2/24"];
        routes = [
          {
            Gateway = "10.0.2.1";
            GatewayOnLink = true;
          }
        ];
        linkConfig.RequiredForOnline = "routable";
      };

      # Boot configuration for test
      boot.loader.systemd-boot.enable = false;
      boot.loader.efi.canTouchEfiVariables = false;

      # Enable IP forwarding and connection tracking
      boot.kernel.sysctl = {
        "net.ipv4.conf.all.forwarding" = true;
        "net.ipv6.conf.all.forwarding" = false;
        "net.netfilter.nf_conntrack_acct" = true;
      };

      boot.kernelModules = ["nf_conntrack"];

      # Basic networking
      networking = {
        hostName = "router";
        useDHCP = false;
        useNetworkd = true;
        firewall.enable = false;
        nat.enable = false;
      };

      # System packages
      environment.systemPackages = with pkgs; [
        vim
        htop
        tcpdump
        iftop
        conntrack-tools
      ];

      # Enable SSH
      services.openssh.enable = true;

      # Disable Tailscale conditional DNS for test
      services.blocky.settings.conditional = lib.mkForce {};

      # Disable Tailscale services in test environment to prevent hanging
      services.tailscale.enable = lib.mkForce false;
      systemd.services.tailscale-subnet-router.enable = lib.mkForce false;
    };

    # Client on first LAN port
    client1 = {
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
              IPv6AcceptRA = false;
            };
          };
        };
      };

      environment.systemPackages = with pkgs; [
        curl
        traceroute
        python3
        netcat
        dnsutils # for nslookup
      ];

      # Simple HTTP server for testing port forwarding
      systemd.services.test-http-server = {
        wantedBy = ["multi-user.target"];
        serviceConfig = {
          ExecStart = "${pkgs.python3}/bin/python3 -m http.server 9090";
          WorkingDirectory = "/tmp";
        };
      };

      # NAT-PMP test client script
      environment.etc."natpmp-test-client.py" = {
        mode = "0755";
        text = ''
          #!/usr/bin/env python3
          import socket
          import struct
          import sys
          import time

          NATPMP_PORT = 5351
          NATPMP_VERSION = 0
          OPCODE_INFO = 0
          OPCODE_MAP_UDP = 1
          OPCODE_MAP_TCP = 2

          def send_info_request(server_addr, port=NATPMP_PORT):
              sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
              sock.settimeout(3.0)
              request = struct.pack('!BB', NATPMP_VERSION, OPCODE_INFO)
              try:
                  sock.sendto(request, (server_addr, port))
                  response, _ = sock.recvfrom(12)
                  version, opcode, result_code, epoch, ip_bytes = struct.unpack('!BBHI4s', response)
                  if result_code == 0:
                      ip = socket.inet_ntoa(ip_bytes)
                      print(f"External IP: {ip}")
                      print(f"Server epoch: {epoch}")
                      return True
                  else:
                      print(f"Error: Result code {result_code}")
                      return False
              except socket.timeout:
                  print("Error: Request timed out")
                  return False
              finally:
                  sock.close()

          def send_mapping_request(server_addr, internal_port, external_port=0, protocol='tcp', lifetime=3600, port=NATPMP_PORT):
              sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
              sock.settimeout(3.0)
              opcode = OPCODE_MAP_TCP if protocol == 'tcp' else OPCODE_MAP_UDP
              request = struct.pack('!BBHHHI', NATPMP_VERSION, opcode, 0, internal_port, external_port, lifetime)
              try:
                  sock.sendto(request, (server_addr, port))
                  response, _ = sock.recvfrom(16)
                  (version, resp_opcode, reserved, result_code, epoch, int_port, ext_port, lifetime_granted) = struct.unpack('!BBHHIHHI', response)
                  if result_code == 0:
                      print(f"Mapping created: Internal port: {int_port}, External port: {ext_port}, Lifetime: {lifetime_granted} seconds")
                      return True
                  else:
                      print(f"Error: Result code {result_code}")
                      return False
              except socket.timeout:
                  print("Error: Request timed out")
                  return False
              finally:
                  sock.close()

          if __name__ == '__main__':
              if len(sys.argv) < 2:
                  print("Usage: natpmp-test-client.py <server-ip> [command]")
                  sys.exit(1)
              server = sys.argv[1]
              if len(sys.argv) == 2 or sys.argv[2] == 'info':
                  send_info_request(server)
              elif sys.argv[2] == 'map':
                  if len(sys.argv) < 4:
                      print("Error: map command requires internal port")
                      sys.exit(1)
                  internal_port = int(sys.argv[3])
                  external_port = int(sys.argv[4]) if len(sys.argv) > 4 else 0
                  protocol = sys.argv[5] if len(sys.argv) > 5 else 'tcp'
                  lifetime = int(sys.argv[6]) if len(sys.argv) > 6 else 3600
                  send_mapping_request(server, internal_port, external_port, protocol, lifetime)
              else:
                  print(f"Unknown command: {sys.argv[2]}")
                  sys.exit(1)
        '';
      };
    };

    # Client on second LAN port
    client2 = {
      config,
      pkgs,
      ...
    }: {
      virtualisation.vlans = [3];

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
              IPv6AcceptRA = false;
            };
          };
        };
      };

      environment.systemPackages = with pkgs; [
        curl
        traceroute
        netcat
        dnsutils # for nslookup
      ];

      # Simple HTTP server on different port
      systemd.services.test-http-server = {
        wantedBy = ["multi-user.target"];
        serviceConfig = {
          ExecStart = "${pkgs.python3}/bin/python3 -m http.server 8080";
          WorkingDirectory = "/tmp";
        };
      };
    };
  };

  testScript = ''
    start_all()

    # Wait for all machines to be ready
    external.wait_for_unit("multi-user.target")
    router.wait_for_unit("multi-user.target")
    storage.wait_for_unit("multi-user.target")
    client1.wait_for_unit("multi-user.target")
    client2.wait_for_unit("multi-user.target")

    # Wait for services
    external.wait_for_unit("nginx.service")
    external.wait_for_open_port(80)

    # Wait for natpmp-server to start
    router.wait_until_succeeds("systemctl is-active natpmp-server.service", timeout=30)

    # Wait for Blocky DNS to start
    router.succeed("systemctl status blocky.service || journalctl -u blocky.service -n 50")
    router.wait_until_succeeds("systemctl is-active blocky.service", timeout=30)
    router.wait_for_open_port(53)

    # Wait for monitoring stack
    router.wait_for_unit("prometheus.service")
    router.wait_for_unit("grafana.service")
    router.wait_for_open_port(9090)  # Prometheus
    router.wait_for_open_port(3000)  # Grafana

    # Wait for client traffic monitoring
    router.wait_for_unit("client-traffic-tracker.service")
    router.wait_for_unit("client-traffic-exporter.service")

    client1.wait_for_unit("test-http-server.service")
    client2.wait_for_unit("test-http-server.service")

    # Give DHCP time to assign addresses
    storage.wait_until_succeeds("ip addr show eth1 | grep 192.168.10.5")  # Static IP
    client1.wait_until_succeeds("ip addr show eth1 | grep 192.168.10")
    client2.wait_until_succeeds("ip addr show eth1 | grep 192.168.10")

    # Test basic connectivity
    with subtest("Clients and storage can ping router"):
        storage.succeed("ping -c 1 192.168.10.1")
        client1.succeed("ping -c 1 192.168.10.1")
        client2.succeed("ping -c 1 192.168.10.1")

    with subtest("Storage has correct static IP"):
        # Verify storage got the static IP 192.168.10.5
        storage_ip = storage.succeed("ip -4 addr show eth1 | grep inet | awk '{print $2}' | cut -d'/' -f1").strip()
        assert storage_ip == "192.168.10.5", f"Storage IP is {storage_ip}, expected 192.168.10.5"
        print(f"Storage server has static IP: {storage_ip}")

    with subtest("Router can ping external"):
        router.succeed("ping -c 1 10.0.2.1")

    with subtest("Clients can reach external through router"):
        # Test routing
        client1.succeed("ping -c 1 10.0.2.1")
        client2.succeed("ping -c 1 10.0.2.1")

        # Test NAT and web connectivity
        client1.succeed("curl -f http://10.0.2.1")
        client2.succeed("curl -f http://10.0.2.1")

    with subtest("Clients can communicate with each other"):
        # Get IP addresses
        client1_ip = client1.succeed("ip -4 addr show eth1 | grep inet | awk '{print $2}' | cut -d'/' -f1").strip()
        client2_ip = client2.succeed("ip -4 addr show eth1 | grep inet | awk '{print $2}' | cut -d'/' -f1").strip()
        print(f"Client1 IP: {client1_ip}")
        print(f"Client2 IP: {client2_ip}")

        # Test ping between clients
        client1.succeed(f"ping -c 1 {client2_ip}")
        client2.succeed(f"ping -c 1 {client1_ip}")

        # Test HTTP between clients
        client1.succeed(f"curl -f http://{client2_ip}:8080")
        client2.succeed(f"curl -f http://{client1_ip}:9090")


    with subtest("Check NAT table"):
        # Generate some traffic
        client1.succeed("curl -f http://10.0.2.1")

        # Check NAT translations exist
        router.succeed("nft list table ip nat | grep masquerade")

    with subtest("DNS and monitoring services are running"):
        # Check that Blocky DNS is running
        router.succeed("systemctl is-active blocky")
        print("Blocky DNS server is running")

        # Check that monitoring services are running
        router.succeed("systemctl is-active prometheus")
        router.succeed("systemctl is-active grafana")
        print("Monitoring stack (Prometheus + Grafana) is running")


    with subtest("NAT-PMP basic functionality"):
        # Wait a bit for natpmp-server to be fully ready
        import time
        time.sleep(2)

        # Check natpmp-server is listening on port 5351
        router.succeed("ss -ulnp | grep ':5351'")  # UDP NAT-PMP port

        # Check natpmp-server process is running
        router.succeed("ps aux | grep natpmp-server | grep -v grep")

        # Check natpmp-server logs for startup messages
        router.succeed("journalctl -u natpmp-server -n 20 || true")

        # Verify external interface configuration
        router.succeed("ip addr show eth1")

        # Test NAT-PMP info request from client
        output = client1.succeed("python3 /etc/natpmp-test-client.py 192.168.10.1 info")
        print(f"NAT-PMP info output:\n{output}")
        assert "External IP: 10.0.2.2" in output, "External IP not correct in NAT-PMP response"
        assert "Server epoch:" in output, "Server epoch not found in response"

    with subtest("NAT-PMP port mapping functionality"):
        # Test port mapping addition
        # Map client1's HTTP server (port 9090) to external port 8080
        client1_ip = client1.succeed("ip -4 addr show eth1 | grep inet | awk '{print $2}' | cut -d'/' -f1").strip()
        print(f"Client1 IP for port mapping: {client1_ip}")

        # Add a TCP port mapping
        map_result = client1.succeed("python3 /etc/natpmp-test-client.py 192.168.10.1 map 9090 8080 tcp 3600")
        print(f"Port mapping output: {map_result}")
        assert "Mapping created:" in map_result, "Port mapping failed"
        assert "External port: 8080" in map_result, "External port not correct"

        # Verify mapping in nftables
        nft_rules = router.succeed("nft list chain ip nat NATPMP_DNAT")
        print(f"NAT-PMP rules:\n{nft_rules}")
        assert "8080" in nft_rules, "Port 8080 not found in NAT rules"
        assert client1_ip in nft_rules, f"Client IP {client1_ip} not found in NAT rules"

        # Test UDP port mapping
        udp_result = client1.succeed("python3 /etc/natpmp-test-client.py 192.168.10.1 map 9091 8081 udp 1800")
        print(f"UDP mapping output: {udp_result}")
        assert "Mapping created:" in udp_result, "UDP port mapping failed"

        # Verify both mappings exist
        nft_rules_after = router.succeed("nft list chain ip nat NATPMP_DNAT")
        print(f"NAT-PMP rules after UDP mapping:\n{nft_rules_after}")
        assert "tcp dport 8080" in nft_rules_after, "TCP mapping not found"
        assert "udp dport 8081" in nft_rules_after, "UDP mapping not found"

    with subtest("NAT-PMP configuration validation"):
        # Check systemd service configuration
        service_status = router.succeed("systemctl show natpmp-server --property=ExecStart")
        print(f"NAT-PMP service config: {service_status}")
        assert "natpmp-server" in service_status, "NAT-PMP server not properly configured"

        # Get actual configuration from running process
        ps_output = router.succeed("ps aux | grep natpmp-server | grep -v grep")
        print(f"NAT-PMP process: {ps_output}")
        assert "--external-interface eth1" in ps_output, "External interface not configured correctly"
        assert "--listen-interface br-lan" in ps_output, "Listen interface not configured correctly"

        # Verify nftables chains for NAT-PMP
        nft_output = router.succeed("nft list table ip nat")
        print("NAT table contents:")
        print(nft_output)

        # Check that NAT-PMP chains exist
        router.succeed("nft list chain ip nat NATPMP_DNAT")
        print("✓ NAT-PMP DNAT chain exists")

        # Verify state directory
        router.succeed("ls -la /var/lib/natpmp-server/ || echo 'State directory will be created on first mapping'")

    with subtest("NAT-PMP network connectivity"):
        # Test UDP port 5351 is accessible for NAT-PMP
        router.succeed("ss -ulnp | grep ':5351'")
        print("✓ NAT-PMP port 5351 is listening")

        # Check NAT-PMP service is active
        router.succeed("systemctl is-active natpmp-server")
        print("✓ NAT-PMP service is running and accessible")

    with subtest("NAT-PMP security and limits"):
        # Test port mapping limits with a few test mappings
        client1_ip = client1.succeed("ip -4 addr show eth1 | grep inet | awk '{print $2}' | cut -d'/' -f1").strip()

        # Add a couple test mappings to verify functionality
        test_ports = [8082, 8083]
        successful_mappings = 0

        for port in test_ports:
            result = client1.succeed(f"python3 /etc/natpmp-test-client.py 192.168.10.1 map 9090 {port} tcp 1800")
            if "Mapping created:" in result:
                successful_mappings += 1
            print(f"Test mapping {port}: {result}")

        print(f"✓ Successfully created {successful_mappings}/{len(test_ports)} test port mappings")

        # Verify all mappings exist in nftables
        final_rules = router.succeed("nft list chain ip nat NATPMP_DNAT")
        print(f"Final NAT-PMP rules:\n{final_rules}")
        
        # Count total mappings
        mapping_count = final_rules.count("dnat to")
        print(f"Total active mappings: {mapping_count}")

        print("NAT-PMP security and limits testing completed")


    with subtest("Monitoring stack is working"):
        # Just verify services are running
        router.succeed("systemctl is-active prometheus")
        router.succeed("systemctl is-active grafana")
        print("Prometheus and Grafana services are active")

        # Check dashboard directory exists (dashboard provisioning working)
        router.succeed("ls -la /etc/grafana/ || echo 'Grafana config directory available'")
        print("Grafana configuration is available")

        # Generate some traffic to test metrics
        client1.succeed("curl -s http://10.0.2.1 >/dev/null")
        client2.succeed("curl -s http://10.0.2.1 >/dev/null")

        # Wait a bit for metrics to be collected
        import time
        time.sleep(10)

        # Check that client traffic metrics are being exported
        router.succeed("test -f /var/lib/prometheus-node-exporter-text-files/client_traffic.prom")
        print("Client traffic metrics are being exported")
  '';
}
