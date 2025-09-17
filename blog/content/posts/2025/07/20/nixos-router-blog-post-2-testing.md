+++
title = "How to Write Tests for Your NixOS Router Configuration"
date = 2025-07-20
aliases = ["/posts/nixos-router-blog-post-2-testing/"]
description = "Learn how to write comprehensive tests for your NixOS router configuration to ensure reliability and catch errors before deployment. Part 2 of the NixOS Router Series."
[taxonomies]
tags = ["nixos", "router", "testing", "networking", "homelab", "tutorial"]
+++

*Part 2 of the NixOS Router Series*

In the [previous post](/posts/nixos-router-getting-started), we built a minimal NixOS router that provides internet connectivity to your network. Now let's ensure it stays reliable by writing comprehensive tests for our configuration.

**Why test your router?** A misconfigured router can leave you without internet access, making it difficult to fix remotely. By writing tests, you can:
- Catch configuration errors before deployment
- Verify features work as expected
- Prevent regressions when making changes
- Document expected behavior

## Moving to Flakes

Starting with this post, we'll use Nix Flakes for a more structured and reproducible configuration. Flakes provide:
- **Reproducible builds** with locked dependencies
- **Better composability** for modular configurations
- **Built-in testing framework** support
- **Easier deployment** with tools like deploy-rs

If you're new to flakes, check out:
- [Official Nix Flakes documentation](https://nixos.wiki/wiki/Flakes)
- [Zero to Nix - Flakes guide](https://zero-to-nix.com/concepts/flakes)
- [My example flake.nix](https://github.com/arsfeld/nixos/blob/master/flake.nix)

To migrate your `/etc/nixos` configuration to flakes:
```bash
# Enable flakes
mkdir -p ~/.config/nix
echo "experimental-features = nix-command flakes" >> ~/.config/nix/nix.conf

# Create a new directory for your flake
mkdir ~/nixos-router
cd ~/nixos-router

# Copy your existing configuration
cp /etc/nixos/configuration.nix .
cp /etc/nixos/hardware-configuration.nix .

# Initialize git (flakes require version control)
git init
git add .

# Create a basic flake.nix
cat > flake.nix << 'EOF'
{
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  
  outputs = { self, nixpkgs }: {
    nixosConfigurations.router = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [ ./configuration.nix ];
    };
  };
}
EOF

# Test your flake
nix flake check
```

## Prerequisites

- A working NixOS router from Part 1
- Basic familiarity with Nix expressions
- Nix with flakes enabled
- About 30 minutes

## Step 1: Introduction to NixOS Tests

NixOS has a powerful testing framework that spins up virtual machines to test your configuration. Tests are written as Nix expressions that:
1. Define virtual machines with your configuration
2. Run test scripts to verify behavior
3. Report success or failure

### Basic Test Structure

Let's look at a real router test from [my configuration](https://github.com/arsfeld/nixos/blob/0933bcd1bf9a3d89e9c666fd46bb33bc8136f3a9/tests/router-test.nix). Create a new file `tests/router-test.nix`:

```nix
{ self, inputs, }: { lib, pkgs, ... }: {
  name = "router-test";
  
  nodes = {
    # The router VM using actual configuration
    router = { config, pkgs, ... }: {
      imports = [
        # Import your router configuration
        "${self}/configuration.nix"
      ];
      
      # Test-specific overrides
      virtualisation.vlans = [1 2 3]; # WAN + 2 LAN ports
      
      # Override hardware-specific settings for VM
      boot.loader.grub.enable = false;
      fileSystems."/" = {
        device = "tmpfs";
        fsType = "tmpfs";
      };
      
      # Override interface names for test environment
      networking.interfaces = lib.mkForce {
        eth1.useDHCP = false;  # WAN
        eth2.ipv4.addresses = [{
          address = "192.168.1.1";
          prefixLength = 24;
        }];
      };
      
      # For test, use static IP on WAN
      networking.interfaces.eth1.ipv4.addresses = [{
        address = "10.0.2.2";
        prefixLength = 24;
      }];
      
      networking.defaultGateway = "10.0.2.1";
      networking.nat.externalInterface = lib.mkForce "eth1";
      networking.nat.internalInterfaces = lib.mkForce [ "eth2" ];
    };
    
    # A client VM to test connectivity
    client1 = { config, pkgs, ... }: {
      virtualisation.vlans = [2];
      
      networking = {
        useDHCP = false;
        useNetworkd = true;
      };
      
      systemd.network = {
        enable = true;
        networks."30-lan" = {
          matchConfig.Name = "eth1";
          networkConfig = {
            DHCP = "yes";
            IPv6AcceptRA = false;
          };
        };
      };
    };
  };
  
  testScript = ''
    start_all()
    
    # Wait for machines to boot
    router.wait_for_unit("multi-user.target")
    client1.wait_for_unit("multi-user.target")
    
    # Your tests here
  '';
}
```

### Running Tests Locally

With flakes, run your test like this:

```bash
nix build .#checks.x86_64-linux.router-test
```

The test framework provides a Python API for controlling VMs and making assertions.

## Step 2: Write Connectivity Tests

Let's write tests that verify our router provides internet access and serves DHCP correctly.

### Test Internet Access

Here's how we test connectivity in the actual router test:

```nix
testScript = ''
  start_all()
  
  # Wait for all machines to be ready
  external.wait_for_unit("multi-user.target")
  router.wait_for_unit("multi-user.target")
  client1.wait_for_unit("multi-user.target")
  
  # Wait for services
  router.wait_for_unit("dnsmasq.service")
  
  # Give DHCP time to assign addresses
  client1.wait_until_succeeds("ip addr show eth1 | grep 192.168.1")
  
  # Test basic connectivity
  with subtest("Clients can ping router"):
      client1.succeed("ping -c 1 192.168.1.1")
  
  with subtest("Router can ping external"):
      router.succeed("ping -c 1 10.0.2.1")
  
  with subtest("Clients can reach external through router"):
      # Test routing
      client1.succeed("ping -c 1 10.0.2.1")
      
      # Test NAT and web connectivity
      client1.succeed("curl -f http://10.0.2.1")
'';
```

### Test LAN Connectivity

Add another client to test LAN-to-LAN communication:

```nix
nodes = {
  # ... existing nodes ...
  
  # Client on second LAN port
  client2 = { config, pkgs, ... }: {
    virtualisation.vlans = [3];
    
    networking = {
      useDHCP = false;
      useNetworkd = true;
    };
    
    systemd.network = {
      enable = true;
      networks."30-lan" = {
        matchConfig.Name = "eth1";
        networkConfig = {
          DHCP = "yes";
          IPv6AcceptRA = false;
        };
      };
    };
  };
};

testScript = ''
  # ... existing tests ...
  
  with subtest("Clients can communicate with each other"):
      # Get IP addresses
      client1_ip = client1.succeed("ip -4 addr show eth1 | grep inet | awk '{print $2}' | cut -d'/' -f1").strip()
      client2_ip = client2.succeed("ip -4 addr show eth1 | grep inet | awk '{print $2}' | cut -d'/' -f1").strip()
      
      # Test ping between clients
      client1.succeed(f"ping -c 1 {client2_ip}")
      client2.succeed(f"ping -c 1 {client1_ip}")
      
      # Test HTTP between clients
      client1.succeed(f"curl -f http://{client2_ip}:8080")
      client2.succeed(f"curl -f http://{client1_ip}:9090")
'';
```

### Test Service Availability

Verify essential services are running:

```nix
testScript = ''
  # ... existing tests ...
  
  with subtest("Core services are running"):
      # Check that dnsmasq is running (provides DHCP and DNS)
      router.succeed("systemctl is-active dnsmasq")
      router.wait_for_open_port(53)  # DNS port
      
      # Check that firewall is active
      router.succeed("systemctl is-active nftables")
'';
```

## Step 3: Test Your Features

Now let's test specific features of your router configuration.

### Test NAT and Firewall Rules

```nix
testScript = ''
  # ... existing tests ...
  
  with subtest("Check NAT table"):
      # Generate some traffic
      client1.succeed("curl -f http://10.0.2.1")
      
      # Check NAT translations exist
      router.succeed("nft list table ip nat | grep masquerade")
'';
```

### Test DHCP Static Reservations

The router test includes a static DHCP reservation test:

```nix
nodes = {
  # Storage server with static IP via DHCP reservation
  storage = { config, pkgs, ... }: {
    virtualisation.vlans = [2];
    
    systemd.network = {
      enable = true;
      # Set MAC address for static DHCP reservation
      links."10-eth1" = {
        matchConfig.OriginalName = "eth1";
        linkConfig.MACAddress = "00:e0:4c:bb:00:e3";
      };
      networks."30-lan" = {
        matchConfig.Name = "eth1";
        networkConfig = {
          DHCP = "yes";
          IPv6AcceptRA = false;
        };
      };
    };
  };
};

testScript = ''
  # ... existing tests ...
  
  with subtest("Storage has correct static IP"):
      # Verify storage got the static IP 192.168.1.50
      storage.wait_until_succeeds("ip addr show eth1 | grep 192.168.1.50")
      storage_ip = storage.succeed("ip -4 addr show eth1 | grep inet | awk '{print $2}' | cut -d'/' -f1").strip()
      assert storage_ip == "192.168.1.50", f"Storage IP is {storage_ip}, expected 192.168.1.50"
'';
```

### Test Port Forwarding (if configured)

If you've added port forwarding rules:

```nix
testScript = ''
  # ... existing tests ...
  
  with subtest("Port forwarding works"):
      # Example: Test if port 80 is forwarded to internal server
      # Assuming you have a rule like:
      # networking.firewall.extraCommands = ''
      #   iptables -t nat -A PREROUTING -p tcp --dport 80 -j DNAT --to-destination 192.168.1.100:80
      # '';
      
      # Start a simple web server on client
      client1.execute("python3 -m http.server 80 &")
      
      # Test from external that port is accessible
      external.succeed("curl -f http://10.0.2.2")
'';
```

## Step 4: Integrate with Deployment

### Pre-deployment Testing

Create a script to run tests before deploying:

```bash
#!/usr/bin/env bash
# deploy-with-tests.sh

set -e

echo "Running router tests..."
nix build .#checks.x86_64-linux.router-test

if [ $? -eq 0 ]; then
    echo "Tests passed! Deploying..."
    nixos-rebuild switch --flake .#router --target-host 192.168.1.1
else
    echo "Tests failed! Deployment cancelled."
    exit 1
fi
```

### Automated Validation

Add a post-deployment validation script:

```nix
# In your router configuration
environment.systemPackages = with pkgs; [
  (writeScriptBin "validate-router" ''
    #!${stdenv.shell}
    set -e
    
    echo "Validating router configuration..."
    
    # Check services
    systemctl is-active dnsmasq.service >/dev/null || (echo "DHCP/DNS failed" && exit 1)
    systemctl is-active nftables.service >/dev/null || (echo "Firewall failed" && exit 1)
    
    # Check connectivity
    ping -c 3 1.1.1.1 >/dev/null || (echo "WAN connectivity failed" && exit 1)
    
    # Check DNS
    nslookup example.com >/dev/null || (echo "DNS resolution failed" && exit 1)
    
    echo "All validations passed!"
  '')
];
```

## Advanced Testing Patterns

> **Note**: The examples in this section are conceptual and untested. They demonstrate possible testing approaches you might want to explore.

### Performance Testing

Test throughput and latency:

```nix
testScript = ''
  # ... existing tests ...
  
  # Install iperf3 for performance testing
  router.succeed("nix-env -iA nixos.iperf3")
  client.succeed("nix-env -iA nixos.iperf3")
  
  # Start iperf3 server on router
  router.execute("iperf3 -s -D")
  
  # Test throughput
  result = client.succeed("iperf3 -c 192.168.1.1 -t 10 -J")
  
  import json
  data = json.loads(result)
  throughput = data['end']['sum_received']['bits_per_second'] / 1_000_000
  print(f"Throughput: {throughput:.2f} Mbps")
  
  # Ensure minimum performance (adjust based on hardware)
  assert throughput > 100, f"Throughput too low: {throughput} Mbps"
'';
```

### Failure Testing

Test recovery from failures:

```nix
testScript = ''
  # ... existing tests ...
  
  # Test DHCP server restart
  router.systemctl("restart dhcpd4.service")
  router.wait_for_unit("dhcpd4.service")
  
  # Client should still get lease after restart
  client.succeed("dhclient -r eth1 && dhclient eth1")
  client.succeed("ping -c 3 192.168.1.1")
  
  # Test firewall reload
  router.succeed("nft flush ruleset")
  router.systemctl("restart nftables.service")
  router.wait_for_unit("nftables.service")
  
  # NAT should still work
  client.succeed("curl -f https://example.com")
'';
```

## Troubleshooting Common Issues

### Tests Hang

If tests hang, add timeouts:

```nix
testScript = ''
  with subtest("DHCP lease acquisition"):
      client.wait_until_succeeds("ip addr show eth1 | grep -q 'inet '", timeout=30)
'';
```

### Debugging Failed Tests

Enable interactive mode to debug:

```bash
nix build .#checks.x86_64-linux.router-test --keep-failed
# Then run the test interactively:
cd result && ./bin/nixos-test-driver --interactive
```

### Resource Constraints

Reduce VM resources if tests fail due to memory:

```nix
nodes = {
  router = { config, pkgs, ... }: {
    virtualisation.memorySize = 512;  # MB
    virtualisation.cores = 1;
  };
};
```

## Summary

You now have a comprehensive test suite for your NixOS router! Your tests verify:

✅ Basic connectivity and DHCP  
✅ Internet access through NAT  
✅ Firewall rules and security  
✅ Service availability  
✅ Configuration-specific features  

With these tests in place, you can confidently make changes knowing you'll catch any issues before they affect your network.

## Next Steps

In the next post, we'll add monitoring to track per-client network usage with custom metrics. You'll gain real-time visibility into which devices are using your bandwidth!

**Continue to:** [Part 3 - Monitor Per-Client Network Usage →](/posts/nixos-router-blog-post-3-monitoring)

For a complete overview of the entire router build including advanced features like QoS, VLANs, and hardware selection, check out my **[NixOS router journey](/posts/nixos-router-journey)** post.

---

*Found this helpful? Check out the [complete test file](https://github.com/arsfeld/nixos/blob/0933bcd1bf9a3d89e9c666fd46bb33bc8136f3a9/tests/router-test.nix) and [full router configuration](https://github.com/arsfeld/nixos) on GitHub.*