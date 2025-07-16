# Router Testing Guide

This guide explains how to test the NixOS router configuration before deploying to production. We use the NixOS VM testing framework to create an isolated test environment.

## Overview

The router test (`tests/router-test.nix`) is a comprehensive test that covers:
- Basic connectivity (WAN/LAN)
- Bridge networking with multiple LAN ports
- NAT functionality
- DHCP server (systemd-networkd)
- DNS server (Blocky with ad-blocking)
- UPnP/NAT-PMP service
- Monitoring stack (Prometheus + Grafana)
- Client-to-client communication

## Available Tests

### 1. Development Test (`router-test`)
A comprehensive router configuration for testing all router features.

Key features tested:
- Bridge networking with multiple LAN ports
- NAT and firewall (nftables)
- DHCP server (systemd-networkd)
- DNS server (Blocky with ad-blocking)
- UPnP/NAT-PMP service
- Monitoring stack (Prometheus + Grafana)

## Running the Tests

```bash
# Enter development shell
nix develop

# Run the development test
just router-test

# In the interactive shell:
# start_all()
# client.wait_for_unit("multi-user.target")
# client.succeed("ping -c 1 192.168.10.1")
```

## Test Structure

The test creates five VMs:
- **External Server** (10.0.2.1): Simulates the internet with a web server
- **Router** (WAN: 10.0.2.2, LAN: 192.168.10.1): The router being tested with:
  - Bridge interface (br-lan) connecting multiple LAN ports
  - Blocky DNS server on port 53 with Tailscale DNS forwarding
  - Tailscale VPN with subnet routing (192.168.10.0/24)
  - Prometheus metrics on port 9090
  - Grafana dashboards on port 3000
  - Static DHCP reservations
- **Storage** (192.168.10.5): Server with static IP via DHCP reservation
- **Client1** (DHCP assigned ~192.168.10.100): First LAN client
- **Client2** (DHCP assigned ~192.168.10.100): Second LAN client on different port

## Common Test Commands

Inside test scripts, you can use:
- `machine.succeed("command")` - Run command, fail test if it fails
- `machine.fail("command")` - Run command, fail test if it succeeds
- `machine.wait_for_unit("service")` - Wait for systemd service
- `machine.wait_for_open_port(port)` - Wait for port to be listening
- `machine.get_screen_text()` - Get console output

## Debugging Tips

1. Use `print()` statements in test scripts
2. Check VM console output with `machine.get_screen_text()`
3. Use interactive mode to manually test commands
4. Add `virtualisation.graphics = false;` to see boot messages
5. Increase VM memory if needed: `virtualisation.memorySize = 2048;`

## Network Topology

```
External Server (10.0.2.1)
       |
    [WAN: 10.0.2.2]
     Router
    [LAN: 192.168.10.1]
    [Tailscale: 100.x.x.x]
       |
    Bridge (br-lan)
    /     |      \
 eth2   eth2    eth3
   |      |       |
Storage Client1 Client2
(.5)   (.100+) (.100+)
```

## What Gets Tested

1. **Basic Connectivity**
   - All clients and storage can ping router LAN interface
   - Router can ping external server
   - Clients can reach external through router

2. **NAT Functionality**
   - Client traffic is properly NATed when going to WAN
   - Web requests from client reach external server

3. **DNS Resolution** (Blocky)
   - Clients use router for DNS (192.168.10.1)
   - DNS queries are resolved through Blocky
   - Ad-blocking is functional
   - **Tailscale domain resolution (*.bat-boa.ts.net)**
   - Conditional forwarding to Tailscale MagicDNS

4. **Static DHCP Reservations**
   - Storage server gets static IP 192.168.10.5
   - MAC address-based reservation works correctly

5. **Tailscale VPN**
   - Tailscale service is running
   - Subnet routing advertises LAN (192.168.10.0/24)
   - Clients can access Tailscale network
   - DNS resolution for Tailscale domains

6. **UPnP/NAT-PMP**
   - UPnP service is running
   - Discovery works from LAN clients
   - Port forwarding works with public IPs

7. **Bridge Networking**
   - Multiple LAN ports bridged together
   - Clients can communicate with each other
   - DHCP works on bridge interface

8. **Monitoring Stack**
   - Prometheus collects metrics from Blocky and system
   - Grafana dashboards show router metrics including:
     - DNS queries and cache hit rates
     - Network traffic per interface
     - **Live network traffic per client IP**
     - **Top clients by bandwidth usage**
     - **Active connections per client**
   - Per-client traffic accounting using nftables counters
   - Real-time bandwidth monitoring for each connected device

## Customizing the Test

### Adding More Test Assertions

You can extend the `testScript` section to test additional functionality:

```python
with subtest("Custom service test"):
    router.wait_for_unit("my-service.service")
    router.succeed("curl localhost:8080")
```

### Testing Specific Services

If you only want to test specific aspects of your router:

1. Create a custom test that imports only the modules you need

### Debugging Failed Tests

1. Run the test interactively to debug failures
2. Check service logs: `router.succeed("journalctl -u servicename")`
3. Inspect network configuration: `router.succeed("ip addr show")`
4. Check firewall rules: `router.succeed("nft list ruleset")`

### Per-Client Traffic Monitoring Implementation

The router test includes sophisticated per-client traffic monitoring:

1. **nftables Traffic Accounting**: A dedicated `CLIENT_TRAFFIC` chain tracks bytes for each client IP
2. **Automatic Client Discovery**: The `client-traffic-tracker` service discovers DHCP clients and adds accounting rules
3. **Prometheus Metrics Export**: The `client-traffic-exporter` service exports metrics as:
   - `client_traffic_bytes_total{ip="192.168.10.x",direction="rx|tx"}` - Total bytes per client
   - `client_active_connections{ip="192.168.10.x"}` - Active connections per client
4. **Grafana Dashboards**: Pre-configured panels show:
   - Real-time bandwidth usage per client
   - Top bandwidth consumers over 24 hours
   - Active connection counts

This enables network administrators to monitor individual device usage in real-time.