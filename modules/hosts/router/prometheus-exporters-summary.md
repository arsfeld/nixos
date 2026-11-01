# Prometheus Exporters Summary for Router

This document summarizes the investigation of NixOS built-in Prometheus exporters and which custom exporters should be kept.

## Exporters Currently in Use

### 1. Node Exporter ✅ (Using NixOS built-in)
- **Module**: `services.prometheus.exporters.node`
- **Status**: Working perfectly with extensive collectors enabled
- **Port**: 9100

### 2. Kea DHCP Exporter ❌ (Keeping custom)
- **Custom module**: `kea-metrics-exporter.nix`
- **Port**: Text files via node exporter
- **Why custom**: The built-in `services.prometheus.exporters.kea` has issues:
  - Fails to connect to unix socket with error "No connection adapters were found"
  - The exporter expects HTTP endpoints, not unix sockets
  - Our custom exporter provides more detailed metrics including pool utilization

### 3. Network Metrics Exporter ✅ (Keeping custom)
- **Custom module**: `network-metrics-exporter` 
- **Port**: 9101
- **Why custom**: No built-in alternative exists for per-client bandwidth monitoring
- **Features**: 
  - Per-client traffic statistics
  - Integration with nftables for accurate metrics
  - Real-time bandwidth usage per IP

### 4. NAT-PMP Exporter ✅ (Built-in support)
- **Source**: natpmp-server includes Prometheus metrics
- **Port**: 9333
- **Status**: Working well, no changes needed

### 5. Blocky DNS Exporter ✅ (Built-in support)
- **Source**: Blocky includes native Prometheus metrics
- **Port**: 4000
- **Status**: Working well, no changes needed

### 6. Speed Test Exporter ✅ (Keeping custom)
- **Custom**: Embedded in monitoring.nix as systemd service
- **Port**: Text files via node exporter
- **Why custom**: No built-in alternative, provides periodic speed tests

### 7. QoS/Traffic Shaping Exporter ✅ (Keeping custom)
- **Custom**: Part of traffic-shaping.nix
- **Port**: Text files via node exporter  
- **Why custom**: No built-in alternative for CAKE qdisc statistics

### 8. UPnP Exporter ⚠️ (Disabled)
- **Custom**: Currently disabled in favor of NAT-PMP
- **Status**: Code exists but not in use

## Recommendations

### Keep Custom Exporters:
1. **kea-metrics-exporter** - More reliable and feature-rich than built-in
2. **network-metrics-exporter** - Unique functionality not available elsewhere
3. **speedtest-exporter** - Provides valuable WAN performance metrics
4. **qos-monitoring** - Essential for traffic shaping visibility

### Potential Future Additions:
1. **systemd exporter** (`services.prometheus.exporters.systemd`) - For service health monitoring
2. **ping exporter** (`services.prometheus.exporters.ping`) - For WAN connectivity monitoring
3. **smokeping exporter** - For latency monitoring

### Third-party Exporters to Consider:
1. **prometheus-nftables-exporter** - Would need packaging, could replace some custom code
2. **speedtest_exporter** - More feature-rich alternative to our custom implementation

## Migration Status to VictoriaMetrics

All exporters work seamlessly with VictoriaMetrics since it maintains full Prometheus compatibility. The only change was updating the scrape configuration to point to VictoriaMetrics instead of Prometheus.

## Conclusion

The custom exporters provide valuable functionality that isn't available in the standard NixOS modules. While the built-in Kea exporter exists, it has compatibility issues with unix sockets. Our custom exporters are well-integrated and provide exactly the metrics needed for router monitoring.