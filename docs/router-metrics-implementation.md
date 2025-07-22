# Router Metrics Implementation Plan

This document outlines the implementation tasks for adding power consumption, Tailscale, and WAN health metrics to the router monitoring system.

## Completed Implementations

### ✅ VictoriaMetrics Migration

**Status**: Completed and deployed

**Changes Made**:
- Replaced Prometheus with VictoriaMetrics for better performance and resource efficiency
- Updated all Grafana dashboards to use VictoriaMetrics datasource
- Migrated alert rules to VictoriaMetrics vmalert format
- Updated reverse proxy configuration for VictoriaMetrics endpoints

**Benefits**:
- Lower memory and CPU usage
- Better storage compression
- Faster query performance
- Full Prometheus compatibility maintained

### ✅ Network Metrics Exporter (formerly client-metrics-exporter)

**Status**: Completed and deployed

**Features Implemented**:
- Real-time per-client bandwidth monitoring with 2-second updates
- Persistent client name caching that survives DHCP lease expiration
- Active connection tracking per client
- Online/offline status monitoring via ARP table
- Direct rate calculation in the exporter (no Prometheus time windows needed)

**Metrics Available**:
```
client_traffic_bytes{direction="rx|tx",ip="192.168.10.x",client="hostname"}
client_traffic_rate_bps{direction="rx|tx",ip="192.168.10.x",client="hostname"}
client_active_connections{ip="192.168.10.x",client="hostname"}
client_status{ip="192.168.10.x",client="hostname"} # 1=online, 0=offline
```

**Implementation Details**:
- Written in Go for efficiency
- Updates every 2 seconds for near real-time monitoring
- Caches client names in `/var/lib/network-metrics-exporter/client-names.cache`
- Reads from nftables traffic accounting rules
- Uses conntrack for connection counting
- Monitors dnsmasq DHCP leases and ARP table

### ✅ Prometheus Exporters Investigation

**Status**: Completed

**Findings**:
- Investigated NixOS built-in Prometheus exporters as replacements for custom exporters
- Attempted to use `services.prometheus.exporters.kea` but it has compatibility issues with unix sockets
- Determined that custom exporters provide unique functionality not available in standard modules

**Exporters to Keep**:
1. **Custom Kea DHCP Metrics Exporter** - More reliable than built-in, provides pool utilization metrics
2. **Custom Network Metrics Exporter** - Unique per-client bandwidth monitoring
3. **Custom Speed Test Exporter** - Periodic WAN performance testing
4. **Custom QoS Monitoring** - Traffic shaping statistics

**Built-in Exporters in Use**:
- Node exporter with extensive collectors
- Blocky DNS (native Prometheus metrics)
- NAT-PMP (native Prometheus metrics)

### ✅ Client Device Integration with Dynamic Discovery

**Status**: Completed with enhanced device type detection

**Features Implemented**:
- Device type labeling for all network metrics
- Dynamic device type inference from hostname patterns and MAC OUI
- Static client definitions from DHCP configuration (only storage server)
- Client database metrics integrated into network-metrics-exporter
- Persistent client name caching across DHCP lease renewals
- MAC address collection from ARP table

**Metrics Available**:
```
# Per-client metrics now include device_type label
client_traffic_bytes{direction="rx|tx",ip="192.168.10.x",client="hostname",device_type="server"}
client_traffic_rate_bps{direction="rx|tx",ip="192.168.10.x",client="hostname",device_type="server"}
client_active_connections{ip="192.168.10.x",client="hostname",device_type="server"}
client_status{ip="192.168.10.x",client="hostname",device_type="server"}

# Client database metrics with job="network-metrics"
network_clients_total          # Total number of known clients
network_clients_online         # Number of currently online clients
network_clients_by_type{type}  # Clients grouped by device type
```

**Device Type Detection**:
1. **Hostname Pattern Matching**: Recognizes common device naming patterns
   - Apple devices: MacBook, iPhone, iPad, Apple-TV
   - Google devices: Google-Home, Nest-Mini, Chromecast
   - IoT devices: HS/KS series (TP-Link), MyQ, Ring, Hue, Wemo
   - Media devices: Roku, FireTV, Shield, Vizio, Samsung-TV
   - Gaming: PlayStation, Xbox, Nintendo
   - Printers: HP, Brother, Canon, Epson patterns
   - Network equipment: switch, router, AP-, UniFi

2. **MAC OUI Lookup**: Identifies vendors from MAC address prefixes
   - Apple, Google, Amazon, TP-Link OUI ranges
   - Falls back to device type based on vendor

3. **Static Definitions**: Only storage server defined statically in `kea-dhcp.nix`

**Implementation Details**:
- Enhanced `inferDeviceType()` function in `main.go`
- `getMacAddress()` function retrieves MAC from ARP table
- Device types: router, server, computer, laptop, phone, tablet, media, iot, printer, gaming, network, unknown
- Client name cache persisted at `/var/lib/network-metrics-exporter/client-names.cache`
- Static clients JSON at `/var/lib/network-metrics-exporter/static-clients.json`

**Grafana Dashboard Updates**:
- Fixed job labels from "client-database" to "network-metrics"
- Added panels for client type distribution
- Device type breakdown visualization

**Future Device Discovery Improvements**:
1. **Phase 1 - Quick Wins**:
   - Enable extended DHCP info in Kea (vendor class identifiers)
   - Add `arp-scan` integration for better vendor lookup
   - Implement mDNS/Avahi name resolution

2. **Phase 2 - Advanced Discovery**:
   - DHCP fingerprinting with local database
   - SSDP/UPnP listener for smart home devices
   - Periodic nmap scans for OS detection

3. **Phase 3 - Comprehensive Solution**:
   - Dedicated device-discovery service aggregating all sources
   - Persistent device database with confidence scores
   - Machine learning for behavioral device classification

See `/docs/router-device-discovery-improvements.md` for detailed research on discovery methods.

## Priority Metrics Implementation

### 1. Power Consumption Metrics

**Objective**: Monitor router power consumption and thermal characteristics to track energy usage and ensure system health.

**Tasks**:
- [ ] Research available power monitoring tools for the router hardware
  - Check for Intel RAPL (Running Average Power Limit) support
  - Investigate if router hardware has PMBus or other power monitoring chips
  - Look for ACPI power metrics availability
- [ ] Create power consumption metrics collector service
  - Read from `/sys/class/powercap/intel-rapl/` if available
  - Monitor CPU package power consumption
  - Track DRAM power consumption if available
  - Export metrics to Prometheus text file format
- [ ] Implement thermal monitoring
  - Read from `/sys/class/thermal/thermal_zone*/temp`
  - Collect CPU core temperatures
  - Monitor chipset/PCH temperatures if available
  - Track NIC temperatures (especially for high-throughput interfaces)
- [ ] Add power state tracking
  - Monitor CPU frequency scaling
  - Track C-state residency
  - Record P-state transitions

**Metrics to collect**:
```
power_consumption_watts{component="cpu_package"}
power_consumption_watts{component="dram"}
power_consumption_watts{component="total"}
temperature_celsius{sensor="cpu_core0"}
temperature_celsius{sensor="cpu_package"}
temperature_celsius{sensor="pch"}
cpu_frequency_mhz{core="0"}
cpu_cstate_residency_percent{state="C0"}
```

### 2. Tailscale Metrics

**Objective**: Monitor Tailscale VPN performance, connectivity, and usage patterns for the subnet router.

**Tasks**:
- [ ] Create Tailscale metrics collector service
  - Parse `tailscale status --json` output
  - Extract peer connection information
  - Monitor connection states and health
- [ ] Implement traffic statistics collection
  - Track bytes sent/received per peer
  - Monitor packet counts
  - Calculate bandwidth utilization
- [ ] Add latency and quality metrics
  - Ping each connected peer periodically
  - Track round-trip times
  - Monitor packet loss rates
- [ ] Collect subnet routing metrics
  - Track advertised routes
  - Monitor route acceptance status
  - Count active subnet connections
- [ ] Monitor Tailscale service health
  - Check daemon status
  - Track connection uptime
  - Monitor authentication state

**Metrics to collect**:
```
tailscale_peer_status{peer="storage.tail-scale.ts.net",status="online"}
tailscale_peer_rx_bytes{peer="storage.tail-scale.ts.net"}
tailscale_peer_tx_bytes{peer="storage.tail-scale.ts.net"}
tailscale_peer_latency_ms{peer="storage.tail-scale.ts.net"}
tailscale_peer_packet_loss_percent{peer="storage.tail-scale.ts.net"}
tailscale_total_peers_connected
tailscale_subnet_routes_advertised
tailscale_daemon_uptime_seconds
tailscale_last_handshake_seconds{peer="storage.tail-scale.ts.net"}
```

### 3. WAN/Internet Health Metrics

**Objective**: Monitor internet connectivity, ISP performance, and WAN link stability.

**Tasks**:
- [ ] Create WAN health monitoring service
  - Check WAN interface link status
  - Monitor IP address changes
  - Track DHCP lease renewals
- [ ] Implement connectivity testing
  - Ping multiple reliable endpoints (8.8.8.8, 1.1.1.1, 9.9.9.9)
  - Calculate packet loss percentages
  - Track jitter and latency variations
- [ ] Add DNS health monitoring
  - Test DNS resolution times to multiple servers
  - Monitor DNSSEC validation if enabled
  - Track DNS query failures
- [ ] Create multi-target availability monitoring
  - Test connectivity to major services (Google, Cloudflare, etc.)
  - Implement HTTP/HTTPS endpoint checking
  - Track service-specific latencies
- [ ] Monitor bandwidth saturation
  - Track WAN interface utilization percentage
  - Detect bufferbloat conditions
  - Monitor packet drops on WAN interface

**Metrics to collect**:
```
wan_link_status{interface="eth0",status="up"}
wan_ip_address_changes_total
wan_uptime_seconds
wan_packet_loss_percent{target="8.8.8.8",interval="60s"}
wan_latency_ms{target="8.8.8.8",type="avg"}
wan_latency_ms{target="8.8.8.8",type="min"}
wan_latency_ms{target="8.8.8.8",type="max"}
wan_jitter_ms{target="8.8.8.8"}
dns_resolution_time_seconds{server="1.1.1.1",query="google.com"}
dns_resolution_failures_total{server="1.1.1.1"}
http_endpoint_reachable{endpoint="https://www.google.com",status="ok"}
http_endpoint_latency_seconds{endpoint="https://www.google.com"}
wan_bandwidth_utilization_percent{direction="download"}
wan_bandwidth_utilization_percent{direction="upload"}
wan_packet_drops_total{interface="eth0"}
```

## Implementation Details

### Service Architecture

Each metric collector will be implemented as a systemd service that:
1. Runs continuously or on a timer
2. Collects metrics from various sources
3. Exports metrics in Prometheus text file format
4. Writes to `/var/lib/prometheus-node-exporter-text-files/`

### File Structure

```
/home/arosenfeld/Projects/nixos/hosts/router/services/
├── monitoring.nix          # Main monitoring configuration (existing)
├── power-metrics.nix       # Power consumption metrics collector
├── tailscale-metrics.nix   # Tailscale VPN metrics collector
└── wan-metrics.nix         # WAN/Internet health metrics collector
```

### Grafana Dashboard Updates

New dashboard panels will be added to visualize:
- Power consumption trends over time
- Temperature heat maps
- Tailscale peer connectivity matrix
- WAN health status overview
- Internet latency and packet loss graphs

## Testing Plan

1. **Unit Testing**
   - Verify each metric collector starts successfully
   - Check metric file generation and format
   - Validate metric values are reasonable

2. **Integration Testing**
   - Confirm Prometheus scrapes new metrics
   - Verify Grafana can query and display metrics
   - Test alert rules if implemented

3. **Load Testing**
   - Monitor collector resource usage
   - Ensure minimal impact on router performance
   - Verify metric collection under high network load

## Timeline

- **Week 1**: Implement power consumption metrics
- **Week 2**: Implement Tailscale metrics
- **Week 3**: Implement WAN health metrics
- **Week 4**: Create Grafana dashboards and test

## Success Criteria

- All three metric categories are successfully collecting data
- Metrics are visible in Prometheus
- Grafana dashboards display meaningful visualizations
- No significant performance impact on router
- Documentation is complete for maintenance

### 4. Log Aggregation with Promtail + Loki

**Objective**: Implement lightweight log collection and aggregation integrated with the existing Grafana/Prometheus stack.

**Tasks**:
- [ ] Deploy Loki service for log storage
  - Configure file-based storage with 7-day retention
  - Optimize for minimal resource usage
  - Set appropriate chunk and index configurations
- [ ] Deploy Promtail service for log collection
  - Collect systemd journal logs
  - Monitor specific service logs (miniupnpd, blocky, nftables)
  - Parse and label logs appropriately
- [ ] Configure Grafana integration
  - Add Loki as datasource
  - Create log dashboard panels
  - Implement log-based alerts
- [ ] Set up log retention policies
  - Align with existing 7-day journal retention
  - Implement automatic cleanup
  - Monitor storage usage

**Key Services to Monitor**:
```
systemd-journald: System logs
miniupnpd: UPnP activity and port mappings
blocky: DNS queries and blocking events
nftables: Firewall events and rule matches
dhcp: Client connections and leases
tailscale: VPN connections and routing
speedtest: Internet performance logs
alertmanager: Alert firing and resolution
```

**Implementation Details**:
- Loki storage: `/var/lib/loki`
- Promtail positions: `/var/lib/promtail`
- Log chunk size: 256KB (optimized for router)
- Index period: 24h
- Retention: 168h (7 days)

## Future Enhancements

After successful implementation of priority metrics:
- Add alerting rules for critical thresholds
- Implement long-term metric retention policies
- Create automated reports for ISP performance
- Add machine learning for anomaly detection
- Extend log parsing for security event correlation

## Current Monitoring Stack Summary

### Time Series Database
- **VictoriaMetrics** (replaced Prometheus)
  - Port: 8428
  - Storage: `/var/lib/victoriametrics`
  - Scrape interval: 30s
  - Full PromQL compatibility

### Visualization
- **Grafana**
  - Port: 3000
  - Access: `/grafana` via Caddy reverse proxy
  - Dashboards: Router metrics with multiple panels for system, network, DNS, DHCP, etc.

### Alerting
- **VictoriaMetrics vmalert**
  - Port: 8880
  - Alert rules for disk space, temperature, bandwidth, CPU, memory, network interfaces
- **Prometheus Alertmanager**
  - Port: 9093
  - Routes alerts to configured notification channels

### Metrics Collection
- **Node Exporter** (port 9100) - System metrics
- **Blocky** (port 4000) - DNS metrics
- **NAT-PMP** (port 9333) - Port mapping metrics
- **Network Metrics Exporter** (port 9101) - Per-client bandwidth, client database, device types
- **Custom exporters** via text files:
  - Kea DHCP metrics
  - Speed test results
  - QoS/traffic shaping statistics

### Log Aggregation
- **Loki** - Log storage and indexing
- **Promtail** - Log collection from systemd journal
- **Grafana** - Log exploration and correlation with metrics