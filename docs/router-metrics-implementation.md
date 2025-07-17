# Router Metrics Implementation Plan

This document outlines the implementation tasks for adding power consumption, Tailscale, and WAN health metrics to the router monitoring system.

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