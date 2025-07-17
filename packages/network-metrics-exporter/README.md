# Network Metrics Exporter

A Prometheus exporter for per-client network metrics on NixOS routers, providing real-time bandwidth monitoring, connection tracking, and client status.

## Features

- **Real-time Bandwidth Monitoring**: Updates every 2 seconds for near-instantaneous metrics
- **Per-Client Traffic Tracking**: Monitor download/upload speeds for each network client
- **Persistent Name Caching**: Client names survive DHCP lease expiration
- **Connection Tracking**: Count active connections per client
- **Online/Offline Status**: Track client availability via ARP table
- **Direct Rate Calculation**: No Prometheus time windows needed - rates calculated in exporter
- **Automatic nftables Setup**: Optional automatic configuration of traffic accounting rules

## Metrics Exposed

### Traffic Metrics
- `client_traffic_bytes{direction="rx|tx",ip="192.168.10.x",client="hostname"}` - Total bytes transferred
- `client_traffic_rate_bps{direction="rx|tx",ip="192.168.10.x",client="hostname"}` - Current bandwidth in bits/sec

### Connection Metrics
- `client_active_connections{ip="192.168.10.x",client="hostname"}` - Number of active connections
- `client_status{ip="192.168.10.x",client="hostname"}` - Online status (1=online, 0=offline)

## Requirements

- NixOS router with nftables
- `conntrack-tools` for connection tracking
- `dnsmasq` for DHCP/DNS services (optional, for name resolution)
- Write access to `/var/lib/network-metrics-exporter/` for name cache

## Installation

### NixOS Configuration

#### Using the NixOS Module (Recommended)

For flake-based configurations:

```nix
# In your host configuration
imports = [
  "${self}/packages/network-metrics-exporter/module.nix"
];

# Enable and configure the service
services.network-metrics-exporter = {
  enable = true;
  
  # Basic configuration
  port = 9101;
  updateInterval = 2; # seconds
  openFirewall = false; # Set to true if needed
  
  # nftables integration (enabled by default)
  enableNftablesIntegration = true; # Automatically set up traffic accounting
  networkPrefix = "192.168.10"; # Your network prefix
  trafficInterface = "br-lan"; # Your LAN interface
};
```

#### Module Options

- `enable`: Enable the network metrics exporter
- `port`: Port to listen on (default: 9101)
- `updateInterval`: Metric update interval in seconds (default: 2)
- `openFirewall`: Whether to open the firewall port (default: false)
- `enableNftablesIntegration`: Automatically set up nftables traffic accounting (default: true)
- `networkPrefix`: Network prefix to monitor (default: "192.168.10")
- `trafficInterface`: Network interface for client discovery (default: "br-lan")
- `package`: Override the exporter package (default: pkgs.network-metrics-exporter)

#### Option 2: Manual Systemd Service

```nix
# Define the service manually
systemd.services.network-metrics-exporter = {
  description = "Network Metrics Exporter";
  wantedBy = [ "multi-user.target" ];
  after = [ "network.target" ];
  
  serviceConfig = {
    Type = "simple";
    ExecStart = "${pkgs.network-metrics-exporter}/bin/network-metrics-exporter";
    Restart = "always";
    RestartSec = "10s";
    
    # Required for nftables access
    User = "root";
    
    # Security hardening
    PrivateTmp = true;
    ProtectSystem = "strict";
    ProtectHome = true;
    ReadOnlyPaths = "/";
    ReadWritePaths = [ "/var/lib/dnsmasq" "/var/lib/network-metrics-exporter" ];
    StateDirectory = "network-metrics-exporter";
    
    # Network capabilities
    AmbientCapabilities = [ "CAP_NET_ADMIN" "CAP_NET_RAW" ];
  };
  
  environment = {
    METRICS_PORT = "9101";
    UPDATE_INTERVAL = "2";
  };
  
  path = with pkgs; [
    nftables
    conntrack-tools
    iproute2
  ];
};
```

### Prometheus Configuration

```yaml
scrape_configs:
  - job_name: 'network-metrics'
    static_configs:
      - targets: ['localhost:9101']
```

## Architecture

The exporter collects metrics from multiple sources:

1. **nftables**: Reads traffic accounting rules for byte counters
   - Automatically sets up CLIENT_TRAFFIC chain when `enableNftablesIntegration` is true
   - Creates per-client TX/RX rules with comment labels
2. **conntrack**: Counts active connections per IP
3. **dnsmasq**: Resolves IP addresses to hostnames via DHCP leases
4. **ARP table**: Determines online/offline status

### nftables Integration

When `enableNftablesIntegration` is enabled (default), the module automatically:
- Creates a `CLIENT_TRAFFIC` chain in the `inet filter` table
- Adds a jump rule from the forward chain
- Dynamically adds per-client rules as clients are discovered
- Updates rules every 60 seconds for new clients

If you prefer to manage nftables rules yourself, set `enableNftablesIntegration = false` and ensure your rules follow this format:
```
# TX rule (client sending)
nft add rule inet filter CLIENT_TRAFFIC ip saddr 192.168.10.100 counter comment "tx_192.168.10.100"

# RX rule (client receiving)
nft add rule inet filter CLIENT_TRAFFIC ip daddr 192.168.10.100 counter comment "rx_192.168.10.100"
```

### Name Resolution

Client names are resolved in the following order:
1. Cached names from previous lookups
2. Static DHCP assignments (`/var/lib/dnsmasq/dhcp-hosts`)
3. Dynamic DHCP leases (`/var/lib/dnsmasq/dnsmasq.leases`)
4. Reverse DNS lookup (if configured)

Names are cached persistently in `/var/lib/network-metrics-exporter/client-names.cache`.

## Grafana Dashboard

The exporter works with custom Grafana dashboards showing:
- Real-time bandwidth usage per client
- Top bandwidth consumers
- Connection count visualization
- Client online/offline status
- Historical traffic patterns

## Configuration

The exporter can be configured via environment variables:

- `METRICS_PORT` - Port to listen on (default: 9101)
- `UPDATE_INTERVAL` - Update interval in seconds (default: 2)

## Development

### Building

```bash
go build -o network-metrics-exporter main.go
```

### Running Locally

```bash
# With default settings
sudo ./network-metrics-exporter

# With custom configuration
sudo METRICS_PORT=9102 UPDATE_INTERVAL=5 ./network-metrics-exporter
```

Note: Requires root access to read nftables and network statistics.

### Testing

```bash
# Check metrics endpoint
curl http://localhost:9101/metrics

# Verify specific client metrics
curl -s http://localhost:9101/metrics | grep client_traffic_rate_bps
```

## Troubleshooting

### No Client Names (Shows "unknown")

1. Check dnsmasq files exist and are readable:
   ```bash
   ls -la /var/lib/dnsmasq/
   ```

2. Verify DHCP leases are being created:
   ```bash
   cat /var/lib/dnsmasq/dnsmasq.leases
   ```

3. Check the name cache:
   ```bash
   cat /var/lib/network-metrics-exporter/client-names.cache
   ```

### No Traffic Data

1. Verify nftables rules exist:
   ```bash
   nft list chain inet filter CLIENT_TRAFFIC
   ```

2. If using `enableNftablesIntegration = true`, check the client-traffic-tracker service:
   ```bash
   systemctl status client-traffic-tracker
   journalctl -u client-traffic-tracker -f
   ```

3. If managing rules manually, ensure they follow the correct format with `tx_IP` and `rx_IP` comments

### High CPU Usage

- Increase update interval in `main.go` (default: 2 seconds)
- Check for excessive number of clients or connections

## License

This project is part of the NixOS router configuration and follows the same licensing terms.

## Contributing

Contributions are welcome! Please ensure:
- Code follows Go best practices
- Metrics follow Prometheus naming conventions
- Documentation is updated for new features