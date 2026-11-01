# Router Dashboard Structure

This directory contains the Grafana dashboard for router monitoring, split into modular parts for better maintainability.

## Structure

- `default.nix` - Main file that combines all dashboard parts and organizes them into sections
- `parts/` - Directory containing dashboard components:
  - `base.json` - Dashboard metadata (title, tags, refresh rate, etc.)
  - `system-panels.json` - System monitoring panels (CPU, Memory, Disk, etc.)
  - `network-interfaces-panels.json` - Network interface statistics
  - `clients-panels.json` - Per-client traffic and connection tracking
  - `dns-panels.json` - DNS query statistics and blocklist metrics
  - `qos-panels.json` - CAKE QoS and traffic shaping metrics
  - `upnp-panels.json` - UPnP/NAT-PMP port forwarding metrics
  - `speedtest-panels.json` - Internet speed test results
  - `uncategorized-panels.json` - Other panels

## Dashboard Organization

The dashboard is automatically organized into the following sections:
1. **System Overview** - CPU, memory, disk, temperature metrics (4 panels per row)
2. **Network Interfaces** - Interface traffic and statistics (2 panels per row)
3. **Client Traffic** - Per-client bandwidth and connections (2 panels per row)
4. **DNS** - Query rates, types, and blocklist stats (3 panels per row)
5. **QoS / Traffic Shaping** - CAKE queue metrics (3 panels per row)
6. **UPnP / Port Forwarding** - Port mapping statistics (2 panels per row)
7. **Internet Speed Test** - Speed test results and latency (2 panels per row)
8. **Other Metrics** - Any uncategorized panels (3 panels per row)

## How it Works

The `default.nix` file:
1. Reads all JSON parts from the `parts/` directory
2. Creates section headers (row panels) for each category
3. Automatically positions panels in a grid layout within each section
4. Calculates proper Y-axis positions to prevent panel overlap
5. Outputs a complete dashboard JSON structure

## Adding New Panels

To add new panels:
1. Add the panel JSON to the appropriate file in `parts/`
2. Ensure panel IDs are unique
3. The dashboard will automatically include and position the new panels

To add a new section:
1. Create a new JSON file in `parts/` for your panels
2. Add the file reading logic in `default.nix`
3. Add a new section in the `buildSections` function

## Benefits

- Easier to manage large dashboards
- Automatic panel positioning and organization
- Consistent layout across sections
- Version control shows clearer diffs
- Panels are organized by functionality
- No manual positioning required