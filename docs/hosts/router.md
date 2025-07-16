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

### 📊 Prometheus & Grafana Stack

Complete monitoring solution with metrics collection and visualization:

```nix
services.prometheus = {
  enable = true;
  port = 9090;
  
  # Scrape configuration
  scrapeConfigs = [
    {
      job_name = "node";
      static_configs = [{ targets = [ "localhost:9100" ]; }];
    }
    {
      job_name = "blocky";
      static_configs = [{ targets = [ "localhost:4000" ]; }];
    }
  ];
  
  # Rules for alerting
  rules = [
    # System alerts (CPU, memory, disk, temperature)
    # Network alerts (interface down, high bandwidth usage)
    # Service alerts (DNS failures, high packet drops)
  ];
};

services.grafana = {
  enable = true;
  port = 3000;
  
  # Dashboard configuration
  provision.dashboards.settings.providers = [
    {
      name = "router";
      path = "/etc/grafana/dashboards";
    }
  ];
};
```

### 📈 Speed Testing

Automated daily internet speed tests with historical tracking:

```nix
systemd.services.speedtest = {
  description = "Internet speed test";
  serviceConfig = {
    Type = "oneshot";
    ExecStart = pkgs.writeScript "speedtest-runner" ''
      #!/bin/bash
      # Run speedtest and export metrics to Prometheus
      RESULT=$(speedtest-cli --json 2>/dev/null || echo '{}')
      
      # Extract metrics and write to textfile collector
      echo "# HELP speedtest_download_mbps Download speed in Mbps" > /var/lib/prometheus/node-exporter/speedtest.prom
      echo "# TYPE speedtest_download_mbps gauge" >> /var/lib/prometheus/node-exporter/speedtest.prom
      echo "speedtest_download_mbps $(echo "$RESULT" | jq -r '.download // 0' | awk '{print $1/1000000}')" >> /var/lib/prometheus/node-exporter/speedtest.prom
      
      echo "# HELP speedtest_upload_mbps Upload speed in Mbps" >> /var/lib/prometheus/node-exporter/speedtest.prom
      echo "# TYPE speedtest_upload_mbps gauge" >> /var/lib/prometheus/node-exporter/speedtest.prom
      echo "speedtest_upload_mbps $(echo "$RESULT" | jq -r '.upload // 0' | awk '{print $1/1000000}')" >> /var/lib/prometheus/node-exporter/speedtest.prom
      
      echo "# HELP speedtest_ping_ms Ping latency in milliseconds" >> /var/lib/prometheus/node-exporter/speedtest.prom
      echo "# TYPE speedtest_ping_ms gauge" >> /var/lib/prometheus/node-exporter/speedtest.prom
      echo "speedtest_ping_ms $(echo "$RESULT" | jq -r '.ping // 0')" >> /var/lib/prometheus/node-exporter/speedtest.prom
    '';
  };
};

systemd.timers.speedtest = {
  description = "Daily internet speed test";
  wantedBy = [ "timers.target" ];
  timerConfig = {
    OnCalendar = "daily";
    Persistent = true;
    RandomizedDelaySec = 3600;
  };
};
```

### 📱 Alerting with ntfy

Push notifications for critical alerts with actionable buttons:

```nix
router.alerting = {
  enable = true;
  
  # Push notifications to mobile
  ntfyUrl = "https://ntfy.sh/your-router-topic";
  
  # Email notifications
  emailConfig.enable = true;
  
  # Alert thresholds
  thresholds = {
    diskUsagePercent = 80;
    temperatureCelsius = 70;
    bandwidthMbps = 2000;
    cpuUsagePercent = 90;
    memoryUsagePercent = 85;
  };
};
```

### Network Statistics
- Interface bandwidth usage
- Connection tracking
- DNS query statistics
- Firewall hit counts
- Internet speed trends
- Client traffic patterns

### Alert Types
- **Critical**: Network interface down, service failures
- **Warning**: High resource usage, temperature alerts
- **Info**: New client connections, speed test results

### Notification Features
- **Mobile Push**: Instant alerts via ntfy app
- **Email**: Detailed alert summaries
- **Action Buttons**: Direct links to silence alerts, view dashboards
- **Smart Grouping**: Reduces notification spam

### Monitoring Access
- **Grafana**: `http://router.bat-boa.ts.net:3000`
  - Username: admin
  - Password: (configured via secrets)
  - Dashboards: Router metrics, speed tests, alerts
- **Prometheus**: `http://router.bat-boa.ts.net:9090`
  - Query interface and targets
  - Alert rule management
- **Alertmanager**: `http://router.bat-boa.ts.net:9093`
  - Active alerts and silences
  - Notification routing

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

# Check speed test results
curl -s http://localhost:9090/api/v1/query?query=speedtest_download_mbps | jq '.data.result[0].value[1]'

# View Grafana dashboards
curl -s http://localhost:3000/api/dashboards/home
```

#### VPN Issues
```bash
# Check WireGuard
wg show

# Check firewall
nft list ruleset | grep 51820
```

#### Monitoring Issues
```bash
# Check Prometheus status
systemctl status prometheus
curl -s http://localhost:9090/api/v1/query?query=up

# Check Grafana status
systemctl status grafana
curl -s http://localhost:3000/api/health

# Check ntfy webhook
systemctl status ntfy-webhook-proxy
journalctl -u ntfy-webhook-proxy -f

# Test alerting
curl -X POST http://localhost:9095 -H "Content-Type: application/json" -d '{"alerts":[{"status":"firing","labels":{"alertname":"TestAlert","severity":"warning"},"annotations":{"summary":"Test alert"}}]}'

# Check speed test timer
systemctl list-timers speedtest
journalctl -u speedtest --since "1 day ago"
```

## Maintenance

### Regular Tasks
- Weekly firewall rule review
- Monthly security updates
- Quarterly firmware updates
- Annual hardware cleaning
- Monthly Grafana dashboard review
- Weekly alert threshold validation
- Daily speed test result review

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
1. **2.5Gb Optimization**: Maximize current network performance
2. **Redundancy**: Secondary router for failover
3. **IDS Enhancement**: Deep packet inspection
4. **VPN Mesh**: Site-to-site connections

### Considerations
- Move to dedicated firewall appliance
- Implement SD-WAN features
- Add network visualization
- Enhance traffic analytics