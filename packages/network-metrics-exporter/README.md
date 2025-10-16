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
- `client_traffic_bytes{direction="rx|tx",ip="192.168.10.x",client="hostname",device_type="..."}` - Total bytes transferred
- `client_traffic_rate_bps{direction="rx|tx",ip="192.168.10.x",client="hostname",device_type="..."}` - Current bandwidth in bits/sec

### Connection Metrics
- `client_active_connections{ip="192.168.10.x",client="hostname",device_type="..."}` - Number of active connections
- `client_status{ip="192.168.10.x",client="hostname",device_type="..."}` - Online status (1=online, 0=offline)

### Client Database Metrics
- `network_clients_total` - Total number of known network clients
- `network_clients_online` - Number of currently online clients
- `network_clients_by_type{type="..."}` - Number of clients by device type

### Hostname Resolution Metrics
- `hostname_cache_hits_total` - Total number of hostname cache hits
- `hostname_cache_misses_total` - Total number of hostname cache misses
- `hostname_cache_invalidations_total{reason="..."}` - Cache invalidations by reason (expired, updated, cleanup-expired, cleanup-stale)
- `hostname_cache_entries` - Current number of entries in hostname cache
- `hostname_resolution_duration_seconds{source="..."}` - Histogram of hostname resolution times by source
- `hostname_resolution_source_total{source="..."}` - Count of hostname resolutions by source
- `network_names_by_source{source="..."}` - Number of names resolved by each source

### WAN Metrics
- `wan_ip_info{interface="...",ip="..."}` - WAN IP address information

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
1. **Cache** - Cached names from previous lookups (24-hour TTL)
2. **DHCP Hosts** - Static DHCP assignments (`/var/lib/kea/dhcp-hosts`)
3. **Kea Leases** - Dynamic DHCP leases from Kea (`/var/lib/kea/kea-leases4.csv` or control socket)
4. **SSDP/UPnP** - Device discovery via UPnP (media devices, smart TVs)
5. **mDNS** - Multicast DNS discovery (Apple devices, IoT)
6. **Reverse DNS** - PTR records via system resolver
7. **NetBIOS** - Windows/Samba name resolution
8. **Static Database** - Custom client database (`/var/lib/network-metrics-exporter/static-clients.json`)
9. **Fallback** - Vendor-based names (e.g., `apple-a1b2`)

#### Cache Behavior

Names are cached persistently in `/var/lib/network-metrics-exporter/client-names.cache` with the following characteristics:

- **TTL**: Cache entries expire after 24 hours
- **Format**: `MAC|Hostname|Source|Timestamp|LastSeenIP`
- **Validation**: Expired entries are automatically invalidated on access
- **Cleanup**: Background task runs hourly to remove stale entries
- **Stale Detection**: Entries for MACs not seen in ARP table for >7 days are removed

The cache tracks:
- The hostname resolved for each MAC address
- Which source provided the name (for debugging)
- When the entry was created/last updated
- The last IP address where the MAC was observed

Cache operations are logged with `[CACHE HIT]`, `[CACHE EXPIRED]`, `[CACHE UPDATE]`, and `[CACHE CLEANUP]` prefixes for troubleshooting.

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

### No Client Names (Shows "unknown" or vendor-based fallback names)

1. **Check Kea DHCP leases**:
   ```bash
   # View current leases
   cat /var/lib/kea/kea-leases4.csv

   # Or query via Kea control socket (if available)
   echo '{ "command": "lease4-get-all", "service": ["dhcp4"] }' | socat - UNIX-CONNECT:/run/kea/kea-dhcp4.sock
   ```

2. **Check DHCP static hosts**:
   ```bash
   cat /var/lib/kea/dhcp-hosts
   ```

3. **Inspect the name cache**:
   ```bash
   # View cache contents (includes source, timestamp, last IP)
   cat /var/lib/network-metrics-exporter/client-names.cache

   # Check cache age and sources
   grep -v "^#" /var/lib/network-metrics-exporter/client-names.cache | head -5
   ```

4. **Check exporter logs for resolution details**:
   ```bash
   journalctl -u network-metrics-exporter -f | grep -E "CACHE|TIMING"
   ```

   Look for:
   - `[CACHE HIT]` - Successfully resolved from cache
   - `[CACHE EXPIRED]` - Cache entry was too old
   - `[CACHE UPDATE]` - Hostname changed for a MAC
   - `[TIMING WARNING]` - Slow resolution (>10ms)

5. **Monitor hostname resolution metrics**:
   ```bash
   curl -s http://localhost:9101/metrics | grep hostname_resolution
   ```

   Key metrics to check:
   - `hostname_cache_hits_total` vs `hostname_cache_misses_total` (cache hit rate)
   - `hostname_resolution_source_total` (which sources are being used)
   - `hostname_cache_invalidations_total` (why entries are being invalidated)

### Stale or Incorrect Client Names

If clients show old/incorrect names despite correct DHCP data:

1. **Check cache entry age**:
   ```bash
   # Cache entries expire after 24 hours
   # Verify the timestamp is recent
   cat /var/lib/network-metrics-exporter/client-names.cache | grep <MAC>
   ```

2. **Force cache invalidation** (restart the service):
   ```bash
   systemctl restart network-metrics-exporter
   ```

   The cache will reload, skipping expired entries.

3. **Clear the cache completely** (if corrupted):
   ```bash
   rm /var/lib/network-metrics-exporter/client-names.cache
   systemctl restart network-metrics-exporter
   ```

4. **Monitor cache cleanup**:
   ```bash
   journalctl -u network-metrics-exporter | grep "CACHE CLEANUP"
   ```

   Cache cleanup runs hourly and logs:
   - Number of expired entries removed (>24 hours old)
   - Number of stale entries removed (MAC not seen in ARP for >7 days)

5. **Verify authoritative sources are updating**:
   ```bash
   # Kea leases should update when clients renew
   stat /var/lib/kea/kea-leases4.csv

   # Check for recent modifications
   ls -lt /var/lib/kea/
   ```

### Slow Hostname Resolution

If resolution is taking too long:

1. **Check resolution duration metrics**:
   ```bash
   curl -s http://localhost:9101/metrics | grep hostname_resolution_duration
   ```

2. **Review timing warnings in logs**:
   ```bash
   journalctl -u network-metrics-exporter | grep "TIMING WARNING"
   ```

   Warnings show which source caused the delay.

3. **Common slow sources**:
   - **dns** (reverse DNS): 2-second timeout if DNS server is unreachable
   - **netbios**: 2-second timeout if nmblookup fails
   - **mdns**: Can be slow if many service types are scanned

4. **Optimize by adding static entries**:
   ```bash
   # Add frequently-accessed clients to dhcp-hosts for fastest resolution
   echo "192.168.10.100 my-device my-device.lan" >> /var/lib/kea/dhcp-hosts
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
- Disable slow discovery methods (SSDP, mDNS) if not needed
- Monitor cache metrics - high invalidation rate may indicate configuration issues

## License

This project is part of the NixOS router configuration and follows the same licensing terms.

## Contributing

Contributions are welcome! Please ensure:
- Code follows Go best practices
- Metrics follow Prometheus naming conventions
- Documentation is updated for new features