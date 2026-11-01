# VictoriaMetrics Migration Summary

This document summarizes the migration from Prometheus to VictoriaMetrics in the router configuration.

## Changes Made

### 1. Monitoring Service (`services/monitoring.nix`)
- Replaced `services.prometheus` with `services.victoriametrics`
- Configured VictoriaMetrics to listen on port 8428 (instead of Prometheus's 9090)
- Migrated all scrape configurations to VictoriaMetrics format
- Updated Grafana datasource from "Prometheus" to "VictoriaMetrics"

### 2. Alerting (`alerting.nix`)
- Replaced Prometheus alert rules with VictoriaMetrics vmalert service
- Created a systemd service for vmalert that:
  - Reads metrics from VictoriaMetrics at http://localhost:8428
  - Sends alerts to Alertmanager at http://localhost:9093
  - Serves its own web interface on port 8880
- Kept Alertmanager configuration unchanged (it's compatible with vmalert)

### 3. Dashboard Updates
- Updated all 10 dashboard JSON files in `dashboards/parts/` to use "VictoriaMetrics" datasource
- Updated `dashboards/default.nix` to use "VictoriaMetrics" datasource

### 4. Reverse Proxy (`services/caddy.nix`)
- Added new endpoint `/victoriametrics` pointing to localhost:8428
- Kept `/prometheus` endpoint for compatibility (also points to VictoriaMetrics)
- Updated Alertmanager configuration

### 5. Web Dashboard (`services/dashboard.html`)
- Updated the dashboard to show "VictoriaMetrics" instead of "Prometheus"
- Updated description to mention vmalert for alerting

## Components Unchanged

- Node exporter configuration remains the same
- Text file collectors (kea-metrics-exporter, traffic-shaping) continue to write to the same directory
- All exporters continue to work as before (blocky, node, network-metrics, natpmp)

## Benefits of VictoriaMetrics

1. **Better Performance**: VictoriaMetrics is more efficient with storage and queries
2. **Lower Resource Usage**: Uses less CPU and memory than Prometheus
3. **Better Compression**: More efficient storage of time-series data
4. **Prometheus Compatibility**: Supports PromQL and Prometheus scraping format
5. **Built-in Clustering**: Easier to scale if needed in the future

## Testing

After deployment, verify:
1. Metrics are being collected: `curl http://localhost:8428/metrics`
2. Grafana dashboards are working properly
3. Alerts are firing correctly through vmalert
4. All exporters are being scraped successfully

## Rollback

If needed, the changes can be reverted by:
1. Reverting the changes in this commit
2. Redeploying the router configuration