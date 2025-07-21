+++
title = "Monitor Per-Client Network Usage with Custom Metrics"
date = 2025-07-22
description = "Set up comprehensive monitoring for your NixOS router with per-device bandwidth tracking, real-time dashboards, and custom Prometheus metrics. Part 3 of the NixOS Router Series."
[taxonomies]
tags = ["nixos", "router", "monitoring", "prometheus", "grafana", "networking", "homelab", "tutorial"]
+++

*Part 3 of the NixOS Router Series*

Ever wondered which device is hogging all your bandwidth? In this guide, we'll set up comprehensive monitoring for your NixOS router that tracks exactly how much data each client uses in real-time. By the end, you'll have beautiful dashboards showing per-device bandwidth usage, connection counts, and network trends.

## What Makes This Special?

Most router monitoring solutions give you aggregate statistics - total bandwidth in and out. That's useful, but it doesn't tell you that your smart TV is downloading 50GB of updates at 3 AM, or that your teenager's gaming PC is saturating your upload bandwidth.

Our custom [network-metrics-exporter](https://github.com/arsfeld/nixos/tree/master/packages/network-metrics-exporter) solves this by:
- Tracking bandwidth per individual client IP
- Maintaining persistent client names across reboots  
- Integrating directly with nftables for accurate counts
- Exposing everything as Prometheus metrics
- Zero performance impact on your routing

## Prerequisites

- A working NixOS router ([from Part 1](./nixos-router-getting-started))
- Your router configuration in a flake (as introduced in [Part 2](./nixos-router-blog-post-2-testing))
- Basic familiarity with NixOS configuration
- About 45 minutes

## Step 1: Set Up Basic Monitoring Stack

First, let's get Prometheus and Grafana running on your router.

### Enable Prometheus

Add to your router configuration:

```nix
# configuration.nix
{
  services.prometheus = {
    enable = true;
    port = 9090;
    
    # Scrape metrics every 15 seconds
    globalConfig = {
      scrape_interval = "15s";
      evaluation_interval = "15s";
    };
    
    # Start with just local node metrics
    scrapeConfigs = [
      {
        job_name = "node";
        static_configs = [{
          targets = [ "localhost:9100" ];
        }];
      }
    ];
  };
  
  # Enable node exporter for system metrics
  services.prometheus.exporters.node = {
    enable = true;
    port = 9100;
    enabledCollectors = [
      "systemd"
      "diskstats"
      "filesystem"
      "loadavg"
      "meminfo"
      "netdev"
      "stat"
      "time"
      "uname"
    ];
  };
}
```

### Enable Grafana

Add Grafana for visualization:

```nix
{
  services.grafana = {
    enable = true;
    settings = {
      server = {
        http_addr = "0.0.0.0";
        http_port = 3000;
        domain = "192.168.1.1";
      };
      
      # Disable analytics
      analytics.reporting_enabled = false;
      
      # Anonymous access for read-only dashboards
      "auth.anonymous" = {
        enabled = true;
        org_role = "Viewer";
      };
    };
    
    # Automatically configure Prometheus datasource
    provision = {
      datasources.settings.datasources = [{
        name = "Prometheus";
        type = "prometheus";
        url = "http://localhost:9090";
        isDefault = true;
      }];
    };
  };
}
```

### Open Firewall Ports

Allow access from your LAN:

```nix
{
  networking.firewall.interfaces."br-lan" = {
    allowedTCPPorts = [ 3000 9090 ];
  };
}
```

Deploy and verify:
```bash
# Update flake inputs to get the module
nix flake update

# Build and switch to the new configuration
sudo nixos-rebuild switch --flake .

# Verify services
curl http://192.168.1.1:3000  # Should see Grafana login
```

## Step 2: Deep Dive - [network-metrics-exporter](https://github.com/arsfeld/nixos/tree/master/packages/network-metrics-exporter)

Now for the star of the show - our custom metrics exporter that makes per-client tracking possible.

### What Makes This Exporter Special

Traditional exporters read from `/proc/net/dev` or similar, giving you interface-level statistics. The [network-metrics-exporter](https://github.com/arsfeld/nixos/tree/master/packages/network-metrics-exporter) is a purpose-built Go program that provides granular, per-client network statistics with minimal overhead.

**Key differences from standard exporters:**

1. **Per-client granularity** - Tracks individual devices, not just interfaces
2. **Zero packet loss** - Uses kernel-level counters, not sampling
3. **Connection tracking** - Shows active connections per client
4. **Persistent device names** - Remembers friendly names across reboots
5. **Efficient design** - Written in Go for minimal resource usage

### Architecture Overview

The exporter consists of two main components working together:

#### 1. The Go Exporter ([`network-metrics-exporter`](https://github.com/arsfeld/nixos/tree/master/packages/network-metrics-exporter))

The main program is written in Go and handles:
- **Prometheus endpoint** - Serves metrics on port 9101
- **State management** - Maintains persistent client names in `/var/lib/network-metrics`
- **Metric collection** - Reads counters and connection tracking data
- **DHCP integration** - Optionally reads DHCP leases for automatic naming

#### 2. The Supporting Service

**`client-traffic-tracker.service`** - A bash script that runs when `enableNftablesIntegration = true`:
- Discovers active clients on your network using ARP and connection tracking
- Creates nftables accounting rules for each client IP
- Monitors for new devices every 60 seconds
- Maintains the `CLIENT_TRAFFIC` chain in nftables

### How nftables Integration Works

When you set `enableNftablesIntegration = true`, the module sets up sophisticated packet accounting:

#### 1. Accounting Tables

The system creates dedicated nftables tables for metrics:

```
table inet filter {
    chain CLIENT_TRAFFIC {
        # TX rules - count outgoing traffic per source IP
        ip saddr 192.168.1.105 counter packets 41234 bytes 3234122 comment "tx_192.168.1.105"
        ip saddr 192.168.1.122 counter packets 8934 bytes 987123 comment "tx_192.168.1.122"
        ip saddr 192.168.1.150 counter packets 72819 bytes 8234122 comment "tx_192.168.1.150"
        
        # RX rules - count incoming traffic per destination IP
        ip daddr 192.168.1.105 counter packets 58239 bytes 87359823 comment "rx_192.168.1.105"
        ip daddr 192.168.1.122 counter packets 7123 bytes 5234122 comment "rx_192.168.1.122"
        ip daddr 192.168.1.150 counter packets 91823 bytes 125789012 comment "rx_192.168.1.150"
    }
    
    chain forward {
        # ... other forward rules ...
        jump CLIENT_TRAFFIC  # All forwarded traffic goes through accounting
    }
}
```

#### 2. Connection Tracking

The exporter also reads from `conntrack` to count active connections:

```bash
# Raw conntrack data
tcp      6 431999 ESTABLISHED src=192.168.1.105 dst=142.250.185.142 sport=55234 dport=443
udp      17 59 src=192.168.1.122 dst=8.8.8.8 sport=51234 dport=53

# Processed into metrics
network_client_connections{ip="192.168.1.105"} 47
network_client_connections{ip="192.168.1.122"} 12
```

#### 3. The Collection Process

Here's how the complete flow works:

1. **Discovery Phase** (client-traffic-tracker):
   ```bash
   # Discover clients via ARP table
   ip neigh show | grep 'br-lan' | grep -E '192.168.1.[0-9]+' | awk '{print $1}'
   
   # Also check active connections
   conntrack -L 2>/dev/null | grep -oE '192.168.1.[0-9]+' | sort -u
   
   # For each discovered IP, create accounting rules
   nft add rule inet filter CLIENT_TRAFFIC ip saddr 192.168.1.105 counter comment "tx_192.168.1.105"
   nft add rule inet filter CLIENT_TRAFFIC ip daddr 192.168.1.105 counter comment "rx_192.168.1.105"
   ```

2. **Collection Phase** ([network-metrics-exporter](https://github.com/arsfeld/nixos/tree/master/packages/network-metrics-exporter)):
   ```go
   // The Go program directly reads nftables counters
   // Parses rules from CLIENT_TRAFFIC chain
   // Reads connection tracking data
   // Enriches with persistent client names
   // Serves metrics on :9101/metrics
   ```

### Performance Characteristics

Real-world measurements from an Intel Celeron N5105 router (4 cores @ 2.0-2.9 GHz) with 25+ active clients:

- **[network-metrics-exporter](https://github.com/arsfeld/nixos/tree/master/packages/network-metrics-exporter) (Go)**:
  - CPU usage: ~1.5% average
  - Memory usage: 7.6MB (peak 11.9MB)
  - Process threads: 9
  - Runtime: 7+ hours stable

- **client-traffic-tracker (Bash)**:
  - CPU usage: < 0.1% (mostly sleeping)
  - Memory usage: < 1MB
  - Wake frequency: Every 60 seconds
  - Runtime: 2+ days stable

- **System impact**:
  - Total CPU overhead: < 2%
  - Total memory: < 10MB combined
  - Network overhead: Zero (uses kernel counters)
  - Load average impact: Negligible (0.09 on a 4-core system)

### Understanding the Metrics

The exporter provides comprehensive metrics:

```prometheus
# Bandwidth metrics (cumulative counters)
network_client_rx_bytes_total{ip="192.168.1.105", hostname="gaming-pc"} 87359823
network_client_tx_bytes_total{ip="192.168.1.105", hostname="gaming-pc"} 3234122

# Connection metrics (current gauge)
network_client_connections{ip="192.168.1.105", hostname="gaming-pc"} 127

# Status metrics
network_client_online{ip="192.168.1.105", hostname="gaming-pc"} 1
network_client_last_seen_timestamp{ip="192.168.1.105", hostname="gaming-pc"} 1703123456

# System information
network_exporter_up 1
network_exporter_scrape_duration_seconds 0.012
```

### Why This Architecture?

The combination of a Go exporter with a bash helper service provides the best of both worlds:

1. **Go Exporter Benefits**:
   - Efficient HTTP server for Prometheus scraping
   - Persistent state management for client names
   - Clean metric formatting and labeling
   - Low memory footprint

2. **Bash Helper Benefits**:
   - Simple client discovery logic
   - Easy integration with system tools (ip, conntrack)
   - Transparent nftables rule management
   - Easy to debug and modify

The bash script handles dynamic rule creation as clients appear, while the Go program efficiently serves the metrics to Prometheus.

## Step 3: Configure the Exporter

Let's enable and configure the [network-metrics-exporter](https://github.com/arsfeld/nixos/tree/master/packages/network-metrics-exporter).

### Basic Configuration

First, add my nixos repository as a flake input to get access to the [network-metrics-exporter](https://github.com/arsfeld/nixos/tree/master/packages/network-metrics-exporter):

```nix
# flake.nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
    arsfeld-nixos.url = "github:arsfeld/nixos";
  };
  
  outputs = { self, nixpkgs, arsfeld-nixos }: {
    nixosConfigurations.router = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [ 
        ./configuration.nix
        arsfeld-nixos.nixosModules.network-metrics-exporter
      ];
    };
  };
}
```

Then configure the exporter in your configuration:

```nix
# configuration.nix
{
  services.network-metrics-exporter = {
    enable = true;
    
    # Network configuration
    lanInterface = "enp2s0";        # Your LAN interface (from Part 1)
    wanInterface = "enp1s0";        # Your WAN interface (from Part 1)
    localSubnet = "192.168.1.0/24"; # Your LAN subnet
    
    # Persistent storage for client names
    stateDir = "/var/lib/network-metrics";
    
    # Update interval (seconds)
    updateInterval = 5;
    
    # Enable nftables integration
    enableNftables = true;
    
    # Web interface port
    port = 9101;
  };
}
```

### Configure Static Client Names

Pre-configure friendly names for known devices:

```nix
{
  services.network-metrics-exporter = {
    staticClients = {
      "192.168.1.105" = "gaming-pc";
      "192.168.1.122" = "smart-tv";
      "192.168.1.135" = "work-laptop";
      "192.168.1.150" = "nas";
    };
  };
}
```

### Advanced Options

```nix
{
  services.network-metrics-exporter = {
    # Automatically detect client names from DHCP leases
    dhcpLeaseFile = "/var/lib/dhcp/dhcpd.leases";
    
    # How long before considering a client offline (seconds)
    offlineThreshold = 300;
    
    # Exclude certain IPs from monitoring
    excludedIPs = [ 
      "192.168.1.1"     # Router itself
      "192.168.1.255"   # Broadcast
    ];
    
    # Extra labels for all metrics
    extraLabels = {
      location = "home";
      router = "main";
    };
  };
}
```

### Add to Prometheus Scraping

Update your Prometheus configuration:

```nix
{
  services.prometheus.scrapeConfigs = [
    # ... existing configs ...
    {
      job_name = "network-metrics";
      static_configs = [{
        targets = [ "localhost:9101" ];
      }];
      # Scrape more frequently for real-time data
      scrape_interval = "5s";
    }
  ];
}
```

## Step 4: Build Powerful Dashboards

Now the fun part - creating dashboards that give you instant visibility into your network usage.

### Import the Pre-Built Dashboard

The easiest way is to import our pre-built dashboard:

```nix
# configuration.nix
{
  services.grafana.provision.dashboards.settings.providers = [{
    name = "default";
    type = "file";
    folder = "Router";
    options.path = ./dashboards;  # Path to your dashboard JSON files
  }];
}
```

### Key Dashboard Panels

The repository includes [pre-built dashboard panels](https://github.com/arsfeld/nixos/tree/b3d094dc94c4e811daaa7fcca99451fcd3e2b1a4/hosts/router/dashboards/parts) that provide comprehensive network visibility:

#### Active Clients Count
Shows the total number of active clients on your network:
```promql
count(count by (ip) (client_active_connections{job="network-metrics"}))
```

#### Client Connection Count Table
Displays each client's active connections in a sortable table:
```promql
client_active_connections{job="network-metrics"}
```

#### Real-time Client Bandwidth
Live graph showing download/upload speeds per client:
```promql
# Download speed (bits per second)
rate(client_traffic_rx_bytes{job="network-metrics"}[1m]) * 8

# Upload speed (bits per second)  
rate(client_traffic_tx_bytes{job="network-metrics"}[1m]) * 8
```

#### Client Bandwidth Analysis
Detailed per-client bandwidth usage over time with legend showing current/avg/max values.

#### Total Bandwidth Gauges
- **Total Download Bandwidth (Mbps)** - Aggregate download across all clients
- **Total Upload Bandwidth (Mbps)** - Aggregate upload across all clients

These panels are defined in [clients-panels.json](https://github.com/arsfeld/nixos/tree/b3d094dc94c4e811daaa7fcca99451fcd3e2b1a4/hosts/router/dashboards/parts/clients-panels.json) and automatically provisioned when you enable Grafana.

The complete dashboard includes multiple sections:
- **[System Overview](https://github.com/arsfeld/nixos/tree/b3d094dc94c4e811daaa7fcca99451fcd3e2b1a4/hosts/router/dashboards/parts/system-panels.json)** - CPU, memory, disk usage
- **[Network Interfaces](https://github.com/arsfeld/nixos/tree/b3d094dc94c4e811daaa7fcca99451fcd3e2b1a4/hosts/router/dashboards/parts/network-interfaces-panels.json)** - WAN/LAN interface statistics
- **[DNS](https://github.com/arsfeld/nixos/tree/b3d094dc94c4e811daaa7fcca99451fcd3e2b1a4/hosts/router/dashboards/parts/dns-panels.json)** - Query rates, cache hits, blocked domains
- **[QoS](https://github.com/arsfeld/nixos/tree/b3d094dc94c4e811daaa7fcca99451fcd3e2b1a4/hosts/router/dashboards/parts/qos-panels.json)** - Traffic shaping and prioritization
- **[NAT-PMP](https://github.com/arsfeld/nixos/tree/b3d094dc94c4e811daaa7fcca99451fcd3e2b1a4/hosts/router/dashboards/parts/natpmp-panels.json)** - Port mapping statistics

All panels are dynamically assembled by [default.nix](https://github.com/arsfeld/nixos/tree/b3d094dc94c4e811daaa7fcca99451fcd3e2b1a4/hosts/router/dashboards/default.nix) into a cohesive dashboard.

> **Note on Declarative Dashboards**: The approach shown here makes your entire monitoring stack declarative and reproducible. Your dashboards are defined as code, version-controlled, and automatically provisioned when you deploy. No more manually recreating dashboards or losing them during upgrades! For a deep dive into declarative Grafana dashboards with NixOS, see the upcoming bonus guide in this series.

### Creating Custom Panels

For a bandwidth usage timeline:

1. Create new panel → Time series
2. Add query: `rate(network_client_rx_bytes_total[1m]) * 8 / 1000000`
3. Legend: `{{hostname}} - Download`
4. Unit: `Mbps`
5. Stack series: Off (to see individual clients)

For a current usage table:

1. Create new panel → Table  
2. Add queries:
   - A: `rate(network_client_rx_bytes_total[1m]) * 8 / 1000000`
   - B: `rate(network_client_tx_bytes_total[1m]) * 8 / 1000000`
   - C: `network_client_connections`
3. Transform → Merge
4. Override columns:
   - A: "Download (Mbps)"
   - B: "Upload (Mbps)"  
   - C: "Connections"

### Dashboard Variables

Add variables for filtering:

```nix
# In your dashboard JSON
"templating": {
  "list": [
    {
      "name": "client",
      "type": "query",
      "query": "label_values(network_client_online, hostname)",
      "multi": true,
      "includeAll": true
    }
  ]
}
```

Then use in queries:
```promql
rate(network_client_rx_bytes_total{hostname=~"$client"}[1m])
```

## Troubleshooting

### No Metrics Appearing

Check the exporter is running:
```bash
systemctl status network-metrics-exporter
curl http://localhost:9101/metrics | grep network_client
```

### Missing Clients

Ensure nftables rules are created:
```bash
sudo nft list table netdev metrics
```

### Incorrect Traffic Counts

Verify interfaces are correct:
```bash
ip link show  # Find your LAN/WAN interfaces
```

### Performance Impact

The exporter is designed for minimal impact:
- Atomic counter reads (no packet loss)
- Efficient rule management
- Configurable update intervals

If you have hundreds of clients, increase the update interval:
```nix
services.network-metrics-exporter.updateInterval = 30;
```

## Advanced Usage

### Alert on Bandwidth Hogs

Add Prometheus alerts:

```nix
{
  services.prometheus.rules = [''
    groups:
    - name: bandwidth
      rules:
      - alert: HighBandwidthUsage
        expr: rate(network_client_rx_bytes_total[5m]) > 100000000  # 100 MB/s
        for: 5m
        annotations:
          summary: "{{ $labels.hostname }} using high bandwidth"
          description: "{{ $labels.hostname }} downloading at {{ $value | humanize }}B/s"
  ''];
}
```

### Track Monthly Quotas

```promql
# Monthly usage in GB
increase(network_client_rx_bytes_total[30d]) / 1073741824
```

### Identify Streaming Devices

```promql
# Sustained bandwidth over 4 Mbps (typical streaming)
avg_over_time(
  rate(network_client_rx_bytes_total[1m])[1h:]
) > 500000
```

## Summary

You now have powerful per-client network monitoring! Your dashboards show:

✅ Real-time bandwidth usage per device  
✅ Historical usage trends  
✅ Connection counts and client status  
✅ Top bandwidth consumers  
✅ Daily/monthly usage totals  

With this visibility, you can finally answer questions like:
- Why is my internet slow right now?
- Which device used all our data this month?
- Is someone streaming 4K video during work hours?
- Are all my IoT devices phoning home constantly?

## Next Steps

In the next post, we'll add automatic port forwarding with a custom NAT-PMP server, making gaming and P2P applications "just work" without manual configuration.

**Continue to:** [Part 4 - Enable Automatic Port Forwarding →](./nixos-router-blog-post-4-natpmp.md)

---

*Found this helpful? Check out the [complete code](https://github.com/arsfeld/nixos/tree/master/packages/network-metrics-exporter) and [full router configuration](https://github.com/arsfeld/nixos) on GitHub.*