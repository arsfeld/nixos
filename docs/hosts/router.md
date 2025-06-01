# Router

## Overview

The router serves as the network gateway and security perimeter for the infrastructure. It provides firewall protection, DNS filtering, VPN access, and traffic management.

## Hardware Specifications

### Physical Hardware
- **Model**: Custom x86_64 mini PC
- **CPU**: Intel N5105 (4 cores @ 2.9GHz)
- **RAM**: 8GB DDR4
- **Storage**: 128GB NVMe SSD
- **Network**: 
  - 4x Intel i226-V 2.5GbE ports
  - 1x Management port
- **Power**: ~15W idle, ~25W load

### Network Interfaces
```
wan0: ISP connection (DHCP/PPPoE)
lan0: LAN bridge (192.168.1.1)
opt1: IoT network (192.168.10.1)
opt2: Guest network (192.168.20.1)
```

## System Configuration

### Base System
```nix
{
  system.stateVersion = "23.11";
  networking.hostName = "router";
  
  # Enable routing
  boot.kernel.sysctl = {
    "net.ipv4.ip_forward" = true;
    "net.ipv6.conf.all.forwarding" = true;
  };
}
```

### Network Configuration
```nix
networking = {
  # Disable NetworkManager
  useDHCP = false;
  useNetworkd = true;
  
  # Bridge configuration
  bridges.lan0.interfaces = [ "enp2s0" "enp3s0" ];
  
  # Interface IPs
  interfaces = {
    lan0.ipv4.addresses = [{
      address = "192.168.1.1";
      prefixLength = 24;
    }];
  };
  
  # NAT configuration
  nat = {
    enable = true;
    externalInterface = "wan0";
    internalInterfaces = [ "lan0" ];
  };
};
```

## Services

### 🛡️ Firewall (nftables)

Advanced stateful firewall with zone-based policies:

```nix
networking.nftables = {
  enable = true;
  ruleset = ''
    table inet filter {
      chain input {
        type filter hook input priority 0; policy drop;
        
        # Allow established
        ct state established,related accept
        
        # Allow local
        iif lo accept
        
        # Allow ICMP
        ip protocol icmp accept
        
        # Allow services
        tcp dport { 22, 53, 80, 443 } accept
        udp dport { 53, 67, 68 } accept
      }
      
      chain forward {
        type filter hook forward priority 0; policy drop;
        
        # Allow established
        ct state established,related accept
        
        # Allow LAN to WAN
        iifname "lan0" oifname "wan0" accept
      }
    }
  '';
};
```

### 🌐 DNS Server (Blocky)

Ad-blocking DNS with privacy protection:

```nix
services.blocky = {
  enable = true;
  settings = {
    # Upstream DNS
    upstream.default = [
      "https://dns.cloudflare.com/dns-query"
      "https://dns.google/dns-query"
    ];
    
    # Ad blocking
    blocking = {
      blackLists = {
        ads = [
          "https://someonewhocares.org/hosts/zero/hosts"
          "https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts"
        ];
      };
      
      # Whitelist
      whiteLists = {
        ads = [
          "github.com"
          "*.github.com"
        ];
      };
    };
    
    # Custom DNS entries
    customDNS = {
      mapping = {
        "router.lan" = "192.168.1.1";
        "storage.lan" = "192.168.1.10";
      };
    };
    
    # Caching
    caching = {
      minTime = "5m";
      maxTime = "30m";
      maxItemsCount = 10000;
    };
  };
};
```

### 🔒 VPN Server (WireGuard)

Secure remote access:

```nix
networking.wireguard.interfaces.wg0 = {
  ips = [ "10.100.0.1/24" ];
  listenPort = 51820;
  
  privateKeyFile = config.age.secrets.wg-private.path;
  
  peers = [
    {
      # Phone
      publicKey = "...";
      allowedIPs = [ "10.100.0.2/32" ];
    }
    {
      # Laptop
      publicKey = "...";
      allowedIPs = [ "10.100.0.3/32" ];
    }
  ];
};
```

### 📊 Traffic Shaping (QoS)

Bandwidth management with CAKE:

```nix
networking.interfaces.wan0 = {
  # Assume 1Gbps connection
  postUp = ''
    tc qdisc add dev wan0 root cake bandwidth 950mbit
    tc qdisc add dev lan0 root cake bandwidth 950mbit
  '';
};
```

### 🎮 UPnP (miniupnpd)

Automatic port forwarding for games/applications:

```nix
services.miniupnpd = {
  enable = true;
  externalInterface = "wan0";
  internalIPs = [ "lan0" ];
  natpmp = true;
};
```

## Network Zones

### LAN (192.168.1.0/24)
- **Purpose**: Trusted internal network
- **Access**: Full internet, all services
- **Devices**: Servers, workstations

### IoT (192.168.10.0/24)
- **Purpose**: Smart home devices
- **Access**: Internet only, no LAN access
- **Devices**: Cameras, sensors, automation

### Guest (192.168.20.0/24)
- **Purpose**: Visitor access
- **Access**: Internet only, isolated
- **Devices**: Guest phones/laptops

## Security Features

### DDoS Protection
```nix
networking.firewall.extraCommands = ''
  # Rate limiting
  iptables -A INPUT -p tcp --syn -m limit --limit 10/s -j ACCEPT
  iptables -A INPUT -p tcp --syn -j DROP
  
  # Connection limits
  iptables -A INPUT -p tcp -m connlimit --connlimit-above 100 -j DROP
'';
```

### IDS/IPS (Suricata)
```nix
services.suricata = {
  enable = true;
  interfaces = [ "wan0" ];
  rules = [
    "emerging-threats"
    "custom-rules"
  ];
};
```

### Fail2ban
```nix
services.fail2ban = {
  enable = true;
  jails = {
    ssh.settings = {
      filter = "sshd";
      maxretry = 3;
      bantime = "1h";
    };
  };
};
```

## Monitoring

### Network Statistics
- Interface bandwidth usage
- Connection tracking
- DNS query statistics
- Firewall hit counts

### Alerts
- WAN connection failure
- High CPU/memory usage
- Unusual traffic patterns
- Failed login attempts

## Backup Configuration

### What's Backed Up
- Firewall rules
- DNS configuration
- VPN keys/configs
- System configuration

### Excluded
- DNS cache
- DHCP leases
- Temporary logs

## Performance Tuning

### Network Optimization
```nix
boot.kernel.sysctl = {
  # Increase network buffers
  "net.core.rmem_max" = 134217728;
  "net.core.wmem_max" = 134217728;
  
  # TCP optimization
  "net.ipv4.tcp_congestion" = "bbr";
  "net.ipv4.tcp_fastopen" = 3;
  
  # Connection tracking
  "net.netfilter.nf_conntrack_max" = 1048576;
};
```

### Hardware Acceleration
- AES-NI for VPN encryption
- RSS for multi-queue NICs
- Hardware timestamping

## Troubleshooting

### Common Issues

#### No Internet Access
```bash
# Check WAN connection
ip addr show wan0
ping -c 4 8.8.8.8

# Check NAT
nft list ruleset | grep masquerade

# Check DNS
dig @127.0.0.1 google.com
```

#### Slow Performance
```bash
# Check CPU usage
htop

# Check network stats
iftop -i wan0

# Check connections
ss -s
```

#### VPN Issues
```bash
# Check WireGuard
wg show

# Check firewall
nft list ruleset | grep 51820
```

## Maintenance

### Regular Tasks
- Weekly firewall rule review
- Monthly security updates
- Quarterly firmware updates
- Annual hardware cleaning

### Log Rotation
```nix
services.logrotate = {
  enable = true;
  settings = {
    "/var/log/firewall.log" = {
      frequency = "weekly";
      rotate = 4;
      compress = true;
    };
  };
};
```

## Disaster Recovery

### Hardware Failure
1. Replace failed hardware
2. Boot NixOS installer
3. Restore configuration
4. Deploy with `nixos-rebuild`

### Configuration Backup
- Git repository for configs
- Automated backup of runtime state
- Documented network topology

## Future Improvements

### Planned Upgrades
1. **10Gb Upgrade**: For faster internal network
2. **Redundancy**: Secondary router for failover
3. **IDS Enhancement**: Deep packet inspection
4. **VPN Mesh**: Site-to-site connections

### Considerations
- Move to dedicated firewall appliance
- Implement SD-WAN features
- Add network visualization
- Enhance traffic analytics