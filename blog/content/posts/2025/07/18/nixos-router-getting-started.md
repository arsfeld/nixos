+++
title = "Build Your Own Router with NixOS: Part 1 - Getting Started"
date = 2025-07-18
description = "Learn how to select hardware and set up a basic NixOS router with internet connectivity, NAT, DHCP, and firewall rules"
[taxonomies]
tags = ["nixos", "router", "networking", "homelab", "tutorial", "hardware"]
+++

![A futuristic mini PC transforming into a network router with glowing ethernet connections](/images/nixos-router-getting-started.png)

**TL;DR**: Turn a $150 mini PC into a powerful, declarative router using NixOS. This guide covers hardware selection, basic installation, and minimal router configuration to get you online.

## Why Build Your Own Router?

Commercial routers often come with limitations: locked-down firmware, poor update cycles, and limited customization. Building your own router with NixOS gives you:

- **Complete control** over your network configuration
- **Declarative configuration** that's version-controlled and reproducible
- **Regular security updates** through NixOS's excellent package management
- **Unlimited customization** for advanced networking features

This is the first in a series of guides that will take you from zero to a fully-featured NixOS router. For a deep dive into my complete router setup and the journey that led here, check out my [NixOS router journey post](/posts/nixos-router-journey/). Let's start with the basics!

## Step 1: Choose Your Hardware

The beauty of building your own router is flexibility in hardware choice. Here's what you need:

### Minimum Requirements
- **2+ network interfaces** (NICs) - one for WAN, one for LAN
- **x86_64 CPU** - NixOS has excellent x86_64 support
- **4GB+ RAM** - More if you plan to run additional services
- **16GB+ storage** - SSD preferred for reliability

### Recommended Budget Option: Intel N5105 Mini PC

For around $150, Intel N5105-based mini PCs offer excellent value:

```
Specifications:
- CPU: Intel Celeron N5105 (4 cores @ 2.0-2.9 GHz)
- RAM: 8GB DDR4 (expandable)
- Storage: 128GB SSD
- Network: 4x Intel i226-V 2.5GbE
- Power: ~10-15W typical consumption
```

### Alternative: ARM-based SBCs

I've also used the NanoPi R2S (ARM-based SBC) as a router, and while my [NixOS configuration still supports it](https://github.com/arsfeld/nixos/tree/master/hosts/r2s), I don't recommend it for beginners:

- **Installation is more complex** - requires building custom images
- **Limited performance** - struggles with QoS, monitoring, and multiple services
- **Feature trade-offs** - you'll need to carefully choose which features to enable
- **Maintenance overhead** - ARM support in NixOS requires more manual work

For a first NixOS router, stick with x86_64 hardware for the best experience.

### Where to Buy
- **AliExpress**: Best prices, 2-4 week shipping
  - Search for "N5105 mini PC 4 LAN"
  - Popular vendors: Topton, CWWK, Beelink
- **Amazon**: Faster shipping, slightly higher prices
  - Look for "fanless mini PC firewall"
- **eBay**: Good for used enterprise hardware
  - Search "Dell Optiplex USFF" + USB NIC

> **Note**: Ensure your chosen hardware has Intel or Realtek NICs for best driver support. Avoid obscure chipsets.

## Step 2: Install NixOS

### Download and Prepare Installation Media

```bash
# Download the latest NixOS ISO (Graphical installer recommended for beginners)
wget https://nixos.org/download/nixos-iso-graphical-24.11.tar.xz

# Write to USB drive (replace /dev/sdX with your USB device)
sudo dd if=nixos-24.11.iso of=/dev/sdX bs=4M status=progress
```

### Installation Process

1. **Boot from USB** and select the graphical installer
2. **Partition your disk** - a simple single partition with ext4 works fine
3. **Set up networking** temporarily for the installation
4. **Create your user** and set passwords
5. **Generate initial configuration**:

```bash
# This creates /etc/nixos/configuration.nix
nixos-generate-config --root /mnt
```

### Advanced Installation Method

For advanced users, I use [disko](https://github.com/nix-community/disko) for declarative disk partitioning and [nix-anywhere](https://github.com/nix-community/nix-anywhere) for remote installations:

- **Disko configuration**: [hosts/router/disk-config.nix](https://github.com/arsfeld/nixos/blob/master/hosts/router/disk-config.nix) - Declaratively defines disk layout
- **Remote deployment**: Can install NixOS on a target machine over SSH without physical access

This approach allows for:
- Reproducible disk partitioning
- Automated remote installations
- Zero-touch deployments

I've automated these tasks in my [justfile](https://github.com/arsfeld/nixos/blob/master/justfile):
```bash
# Install router configuration on new hardware
just install router 192.168.1.100

# Deploy updates to existing router
just deploy router

# List network interfaces for configuration
just router-interfaces router.local
```

See my [deployment documentation](https://github.com/arsfeld/nixos#deployment) for detailed examples.

### Identify Your Network Interfaces

Before configuring the router, identify your NICs:

```bash
# List all network interfaces
ip link show

# You should see something like:
# enp1s0: WAN interface (connect to modem)
# enp2s0: LAN interface (connect to switch/devices)
```

## Step 3: Create Minimal Router Configuration

Replace your `/etc/nixos/configuration.nix` with this minimal router setup. We'll use dnsmasq which provides both DHCP and DNS services in a single, lightweight package:

```nix
{ config, pkgs, ... }:

{
  imports = [ ./hardware-configuration.nix ];

  # Basic system configuration
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  networking.hostName = "nixos-router";
  
  # Enable IP forwarding
  boot.kernel.sysctl = {
    "net.ipv4.ip_forward" = 1;
    "net.ipv6.conf.all.forwarding" = 1;
  };

  # Configure network interfaces
  networking = {
    # Disable NetworkManager for manual configuration
    networkmanager.enable = false;
    useDHCP = false;

    # WAN interface (adjust interface name as needed)
    interfaces.enp1s0 = {
      useDHCP = true;  # Get IP from ISP
    };

    # LAN interface
    interfaces.enp2s0 = {
      ipv4.addresses = [{
        address = "192.168.1.1";
        prefixLength = 24;
      }];
    };

    # NAT for internet sharing
    nat = {
      enable = true;
      externalInterface = "enp1s0";  # WAN
      internalInterfaces = [ "enp2s0" ];  # LAN
    };

    # Simple firewall rules
    firewall = {
      enable = true;
      
      # Allow SSH from LAN only
      extraCommands = ''
        iptables -A nixos-fw -p tcp --dport 22 -s 192.168.1.0/24 -j ACCEPT
      '';
    };
  };

  # DHCP and DNS server (dnsmasq provides both)
  services.dnsmasq = {
    enable = true;
    settings = {
      # DHCP Configuration
      dhcp-range = [ "192.168.1.100,192.168.1.200,12h" ];
      interface = "enp2s0";
      
      # DNS Configuration  
      server = [ "8.8.8.8" "8.8.4.4" ];  # Upstream DNS servers
      
      # Don't use /etc/hosts
      no-hosts = true;
      
      # DHCP Options
      dhcp-option = [
        "option:router,192.168.1.1"
        "option:dns-server,192.168.1.1"  # Use router as DNS server
      ];
    };
  };

  # Basic services
  services.openssh.enable = true;

  # User configuration
  users.users.admin = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];  # Enable 'sudo'
    # Don't forget to set a password with 'passwd admin'
  };

  system.stateVersion = "24.11";
}
```

### Apply the Configuration

```bash
# Switch to the new configuration
sudo nixos-rebuild switch

# Check service status
systemctl status dnsmasq
systemctl status nftables
```

## Step 4: Test Your Router

### Verify WAN Connectivity

```bash
# Check if router has internet
ping -c 3 google.com

# Check WAN IP address
ip addr show enp1s0
```

### Test LAN Connectivity

1. **Connect a device** to your LAN port (enp2s0)
2. **Verify DHCP** - the device should get an IP in 192.168.1.100-200 range
3. **Test internet access** from the connected device

### Basic Troubleshooting

If things aren't working:

```bash
# Check interface status
ip link show
ip addr show

# Monitor DHCP leases
journalctl -u dnsmasq -f

# View active DHCP leases
cat /var/lib/dnsmasq/dnsmasq.leases

# Check firewall rules
sudo nft list ruleset

# Watch packet flow
sudo tcpdump -i enp2s0 -n
```

### Common Issues and Fixes

**No internet on LAN devices?**
- Verify NAT is working: `sudo iptables -t nat -L -v -n`
- Check IP forwarding: `sysctl net.ipv4.ip_forward`

**DHCP not working?**
- Ensure dnsmasq is running: `systemctl status dnsmasq`
- Check logs: `journalctl -u dnsmasq`
- View leases: `cat /var/lib/dnsmasq/dnsmasq.leases`

**Can't access router via SSH?**
- Verify firewall allows SSH from LAN: `sudo iptables -L -v -n`

## What's Next?

Congratulations! You now have a working NixOS router. It's basic, but it's yours. Continue with the series to add more features:

- **[Part 2: Testing Your Configuration](/posts/nixos-router-blog-post-2-testing)** - Write comprehensive tests to ensure reliability and catch errors before deployment
- **[Part 3: Per-Client Monitoring](/posts/nixos-router-blog-post-3-monitoring)** - Track bandwidth usage per device with Prometheus and Grafana

For a complete overview of the entire router build including advanced features like QoS, VLANs, and hardware selection, check out my **[NixOS router journey](/posts/nixos-router-journey)** post.

The complete configuration for this series is available in my [nixos-config repository](https://github.com/arsfeld/nixos). Feel free to explore and adapt it to your needs.

## Resources

- [NixOS Manual - Networking](https://nixos.org/manual/nixos/stable/#sec-networking)
- [My Router Configuration](https://github.com/arsfeld/nixos/tree/master/hosts/router)
- [NixOS Discourse - Networking Topics](https://discourse.nixos.org/c/help/networking/23)

Have questions or run into issues? Feel free to open an issue on the [repository](https://github.com/arsfeld/nixos/issues) or reach out on the NixOS forums!