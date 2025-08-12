# Streamlit VPN Manager - Implementation Guide

## Overview

A lightweight Python-based VPN manager using Streamlit for the web interface. This provides per-client VPN routing control with minimal dependencies and simple state management.

## Features

- **Client Discovery**: Automatically discovers network clients via ARP table and DHCP leases
- **Per-Client VPN Toggle**: Enable/disable VPN routing for individual devices
- **Custom Names**: Assign friendly names to devices
- **State Persistence**: Maintains settings in a JSON file
- **NFT Integration**: Generates nftables rules for traffic routing
- **Real-time Status**: Shows online/offline status for each client

## Architecture

```
┌─────────────────┐
│   Streamlit UI  │
│  (Web Interface)│
└────────┬────────┘
         │
┌────────▼────────┐
│  Python Script  │
│  (vpn-manager)  │
└────────┬────────┘
         │
    ┌────┴────┬──────────┬───────────┐
    │         │          │           │
┌───▼──┐ ┌───▼───┐ ┌────▼────┐ ┌────▼────┐
│ ARP  │ │ DHCP  │ │  JSON   │ │   NFT   │
│Table │ │Leases │ │  State  │ │  Rules  │
└──────┘ └───────┘ └─────────┘ └─────────┘
```

## Quick Start

### 1. Run Directly with UV

```bash
# Make executable
chmod +x vpn-manager.py

# Run directly (uv will handle dependencies)
./vpn-manager.py

# Or with explicit uv command
uv run vpn-manager.py
```

### 2. Access Web Interface

Open browser to `http://router-ip:8501`

### 3. Enable for Clients

1. Find client in the list
2. Toggle VPN switch to enable
3. Click "Apply VPN Routing Rules"
4. Confirm to apply nftables rules

## Installation on NixOS

### Option 1: As a System Service

Add to your router configuration:

```nix
{
  imports = [
    ./path/to/vpn-manager-module.nix
  ];
  
  services.vpn-manager = {
    enable = true;
    port = 8501;
    openFirewall = true;  # Allow LAN access
  };
}
```

### Option 2: Manual Installation

```bash
# Copy files to router
scp vpn-manager.py router:/opt/vpn-manager/

# Run manually
ssh router
cd /opt/vpn-manager
./vpn-manager.py
```

## How It Works

### Client Discovery

1. **ARP Table Parsing**: Reads `/proc/net/arp` or `ip neigh` output
2. **DHCP Lease Files**: 
   - dnsmasq: `/var/lib/misc/dnsmasq.leases`
   - Kea: `/var/lib/kea/kea-leases4.csv`
3. **Merges Data**: Combines MAC, IP, hostname, and online status

### State Management

State stored in `/tmp/vpn-manager-state.json` (configurable):

```json
{
  "clients": {
    "AA:BB:CC:DD:EE:FF": {
      "vpn_enabled": true,
      "name": "John's Laptop",
      "updated_at": "2024-01-15T10:30:00"
    }
  },
  "vpn_enabled": true
}
```

### VPN Routing

When VPN is enabled for a client:

1. **Packet Marking**: Marks packets from client IP
2. **Policy Routing**: Routes marked packets through VPN interface
3. **NAT**: Masquerades traffic through VPN interface

Generated nftables rules example:

```nft
table ip vpn_manager {
    chain prerouting {
        type filter hook prerouting priority mangle;
        
        # Mark packets from VPN clients
        ip saddr 192.168.1.100 meta mark set 0x64
        ip saddr 192.168.1.101 meta mark set 0x65
    }
    
    chain postrouting {
        type nat hook postrouting priority srcnat;
        
        # NAT through VPN
        meta mark 0x64 oifname "wg0" masquerade
        meta mark 0x65 oifname "wg0" masquerade
    }
}
```

## Configuration

### Environment Variables

- `STREAMLIT_SERVER_PORT`: Web interface port (default: 8501)
- `STREAMLIT_SERVER_ADDRESS`: Bind address (default: 0.0.0.0)
- `VPN_MANAGER_STATE_FILE`: State file path (default: /tmp/vpn-manager-state.json)

### Customization

Edit these constants in `vpn-manager.py`:

```python
# VPN interface name
vpn_interface = "wg0"  # Change to your VPN interface

# LAN interfaces to monitor
lan_interfaces = ['br-lan', 'eth0', 'lan']

# State file location
state_file = Path('/tmp/vpn-manager-state.json')
```

## Requirements

- Python 3.11+
- Root/sudo access (for ARP table and nftables)
- uv package manager
- WireGuard or other VPN already configured

## Security Considerations

1. **Local Access Only**: Default configuration binds to all interfaces - restrict with firewall rules
2. **No Authentication**: Add reverse proxy with auth for production
3. **Privilege Requirements**: Needs CAP_NET_ADMIN for network operations

## Troubleshooting

### No Clients Showing

```bash
# Check ARP table manually
ip neigh show

# Check permissions
sudo ./vpn-manager.py
```

### NFT Rules Not Applying

```bash
# Check nftables service
systemctl status nftables

# Verify rules manually
nft list ruleset
```

### State Not Persisting

```bash
# Check state file permissions
ls -la /tmp/vpn-manager-state.json

# Use different location
VPN_MANAGER_STATE_FILE=/var/lib/vpn-manager/state.json ./vpn-manager.py
```

## Extending

### Add VPN Providers

Modify `NFTManager.generate_rules()` to support multiple VPN interfaces:

```python
def generate_rules(vpn_clients: Dict[str, str]) -> str:
    # vpn_clients = {"192.168.1.100": "wg-pia", "192.168.1.101": "wg-mullvad"}
    for client_ip, vpn_interface in vpn_clients.items():
        # Generate rules per interface
        pass
```

### Add Metrics

Export client status to Prometheus:

```python
def export_metrics():
    metrics = []
    for client in clients:
        metrics.append(f'vpn_client_enabled{{mac="{client.mac}"}} {int(client.vpn_enabled)}')
    return "\n".join(metrics)
```

## Comparison with Go Version

| Feature | Streamlit Version | Go Version |
|---------|------------------|------------|
| Language | Python | Go |
| UI Framework | Streamlit | Alpine.js + Templates |
| Database | JSON file | BadgerDB |
| Dependencies | Minimal (uv managed) | Compiled binary |
| Setup Complexity | Low | Medium |
| Performance | Good for <100 clients | Excellent |
| Memory Usage | ~50MB | ~10MB |
| Development Speed | Fast | Medium |

## Next Steps

1. **Authentication**: Add basic auth or Tailscale auth
2. **Multiple VPNs**: Support routing to different VPN providers
3. **Scheduling**: Time-based VPN enable/disable
4. **Bandwidth Monitoring**: Show per-client traffic stats
5. **Kill Switch**: Block non-VPN traffic for selected clients