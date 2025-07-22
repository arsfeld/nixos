# VPN Manager Implementation Guide

## Overview

The VPN Manager is a module within the Router UI Phoenix application that enables per-client VPN routing. It allows administrators to assign individual network clients to different VPN providers, creating isolated VPN tunnels for enhanced privacy and network segmentation.

## Key Features

1. **Per-Client VPN Assignment** - Assign individual devices to specific VPN providers
2. **Multiple VPN Providers** - Support for multiple simultaneous VPN connections
3. **Traffic Isolation** - Complete isolation between VPN and non-VPN traffic
4. **Kill Switch** - Blocks internet access if VPN connection drops
5. **Real-time Monitoring** - Live status of VPN connections and client routing

## Technical Implementation

### 1. WireGuard Interface Management

Each VPN provider gets its own WireGuard interface:

```bash
# Example interfaces
wg-pia      # Private Internet Access
wg-mullvad  # Mullvad VPN
wg-nordvpn  # NordVPN
```

The VPN Manager creates and manages these interfaces dynamically using Elixir ports:

```elixir
defmodule RouterUI.VPNManager.WireGuardService do
  def create_interface(provider) do
    # Generate interface name
    interface = "wg-#{provider.slug}"
    
    # Create WireGuard interface
    System.cmd("ip", ["link", "add", "dev", interface, "type", "wireguard"])
    
    # Configure interface
    config = generate_wireguard_config(provider)
    File.write!("/etc/wireguard/#{interface}.conf", config)
    
    # Apply configuration
    System.cmd("wg", ["setconf", interface, "/etc/wireguard/#{interface}.conf"])
    
    # Bring interface up
    System.cmd("ip", ["link", "set", "up", "dev", interface])
  end
end
```

### 2. NFTables Rules Architecture

The VPN Manager generates NFTables rules for traffic routing:

```nft
# VPN routing table
table ip vpn_routing {
    # Mark packets from VPN clients
    chain prerouting {
        type filter hook prerouting priority mangle;
        
        # Client 192.168.1.100 -> PIA VPN (mark 100)
        ip saddr 192.168.1.100 meta mark set 0x64
        
        # Client 192.168.1.101 -> Mullvad VPN (mark 101)
        ip saddr 192.168.1.101 meta mark set 0x65
    }
    
    # Route marked packets through VPN
    chain postrouting {
        type nat hook postrouting priority srcnat;
        
        # PIA VPN NAT
        meta mark 0x64 oifname "wg-pia" masquerade
        
        # Mullvad VPN NAT
        meta mark 0x65 oifname "wg-mullvad" masquerade
    }
    
    # Kill switch - drop non-VPN traffic
    chain forward {
        type filter hook forward priority filter;
        
        # Allow established connections
        ct state established,related accept
        
        # Drop marked packets not going through VPN
        meta mark 0x64 oifname != "wg-pia" drop
        meta mark 0x65 oifname != "wg-mullvad" drop
    }
}
```

### 3. Policy-Based Routing

IP rules for routing table selection:

```bash
# Routing table for each VPN
echo "100 pia" >> /etc/iproute2/rt_tables
echo "101 mullvad" >> /etc/iproute2/rt_tables

# Add rules for marked packets
ip rule add fwmark 0x64 table pia
ip rule add fwmark 0x65 table mullvad

# Add default routes through VPN interfaces
ip route add default dev wg-pia table pia
ip route add default dev wg-mullvad table mullvad
```

### 4. Client Discovery Integration

The VPN Manager integrates with Kea DHCP to discover clients:

```elixir
defmodule RouterUI.VPNManager.ClientDiscovery do
  use GenServer
  
  def init(_) do
    # Monitor Kea lease file
    :fs.subscribe("/var/lib/kea/kea-leases4.csv")
    
    # Initial client load
    clients = parse_kea_leases()
    {:ok, %{clients: clients}}
  end
  
  def handle_info({:fs, :file_event}, state) do
    # Reload clients on lease file change
    clients = parse_kea_leases()
    broadcast_client_update(clients)
    {:noreply, %{state | clients: clients}}
  end
end
```

### 5. LiveView UI Components

The web interface uses Phoenix LiveView for real-time updates:

```elixir
defmodule RouterUIWeb.VPNManagerLive.ClientList do
  use RouterUIWeb, :live_component
  
  def render(assigns) do
    ~H"""
    <div class="overflow-x-auto">
      <table class="table table-zebra w-full">
        <thead>
          <tr>
            <th>Device</th>
            <th>IP Address</th>
            <th>MAC Address</th>
            <th>VPN Provider</th>
            <th>Status</th>
            <th>Actions</th>
          </tr>
        </thead>
        <tbody>
          <%= for client <- @clients do %>
            <tr>
              <td><%= client.hostname %></td>
              <td><%= client.ip %></td>
              <td class="font-mono text-sm"><%= client.mac %></td>
              <td>
                <select 
                  class="select select-bordered select-sm"
                  phx-change="assign_vpn"
                  phx-value-client={client.id}>
                  <option value="">No VPN</option>
                  <%= for provider <- @providers do %>
                    <option value={provider.id} selected={client.vpn_id == provider.id}>
                      <%= provider.name %>
                    </option>
                  <% end %>
                </select>
              </td>
              <td>
                <%= if client.vpn_connected do %>
                  <div class="badge badge-success gap-2">
                    <div class="w-2 h-2 bg-current rounded-full animate-pulse"></div>
                    Connected
                  </div>
                <% else %>
                  <div class="badge badge-ghost">Not Connected</div>
                <% end %>
              </td>
              <td>
                <button class="btn btn-ghost btn-xs" phx-click="toggle_killswitch" phx-value-client={client.id}>
                  Kill Switch <%= if client.killswitch, do: "ON", else: "OFF" %>
                </button>
              </td>
            </tr>
          <% end %>
        </tbody>
      </table>
    </div>
    """
  end
end
```

## Database Schema

```sql
-- VPN Providers
CREATE TABLE vpn_providers (
    id SERIAL PRIMARY KEY,
    name VARCHAR(255) NOT NULL,
    slug VARCHAR(50) UNIQUE NOT NULL,
    type VARCHAR(50) NOT NULL, -- 'wireguard', 'openvpn'
    endpoint VARCHAR(255) NOT NULL,
    public_key TEXT,
    private_key TEXT ENCRYPTED,
    preshared_key TEXT ENCRYPTED,
    config JSONB,
    enabled BOOLEAN DEFAULT true,
    created_at TIMESTAMP,
    updated_at TIMESTAMP
);

-- Client VPN Mappings
CREATE TABLE client_vpn_mappings (
    id SERIAL PRIMARY KEY,
    client_mac MACADDR UNIQUE NOT NULL,
    client_ip INET,
    client_hostname VARCHAR(255),
    vpn_provider_id INTEGER REFERENCES vpn_providers(id),
    enabled BOOLEAN DEFAULT true,
    kill_switch BOOLEAN DEFAULT false,
    created_at TIMESTAMP,
    updated_at TIMESTAMP
);

-- VPN Connection Status
CREATE TABLE vpn_connection_status (
    id SERIAL PRIMARY KEY,
    provider_id INTEGER REFERENCES vpn_providers(id),
    interface_name VARCHAR(50),
    connected BOOLEAN DEFAULT false,
    connected_at TIMESTAMP,
    disconnected_at TIMESTAMP,
    bytes_sent BIGINT,
    bytes_received BIGINT,
    last_handshake TIMESTAMP,
    endpoint_ip INET,
    created_at TIMESTAMP,
    updated_at TIMESTAMP
);
```

## Monitoring Integration

### VictoriaMetrics Metrics

The VPN Manager exports metrics to VictoriaMetrics:

```elixir
defmodule RouterUI.VPNManager.Metrics do
  def export_metrics do
    providers = VPNManager.list_providers()
    
    Enum.each(providers, fn provider ->
      status = VPNManager.get_connection_status(provider)
      
      # Connection status
      push_metric("vpn_connection_status", 
        status.connected && 1 || 0,
        %{provider: provider.name, interface: provider.interface_name})
      
      # Traffic metrics
      push_metric("vpn_bytes_sent", status.bytes_sent, %{provider: provider.name})
      push_metric("vpn_bytes_received", status.bytes_received, %{provider: provider.name})
      
      # Client count
      client_count = VPNManager.count_clients_on_vpn(provider)
      push_metric("vpn_client_count", client_count, %{provider: provider.name})
    end)
  end
end
```

### Grafana Dashboard

Create dashboard panels for:

1. VPN connection status (up/down)
2. Traffic throughput per VPN
3. Client distribution across VPNs
4. Connection uptime/stability
5. Latency measurements

## Security Considerations

1. **Credential Storage**
   - VPN credentials encrypted with age
   - Keys never exposed in UI
   - Audit log for all changes

2. **Network Isolation**
   - Separate network namespace per VPN
   - Strict firewall rules
   - No cross-VPN communication

3. **Access Control**
   - Admin authentication required
   - Read-only view for monitoring
   - API tokens for automation

## Testing

### Unit Tests

```elixir
defmodule RouterUI.VPNManagerTest do
  use RouterUI.DataCase
  
  describe "client assignment" do
    test "assigns client to VPN provider" do
      provider = insert(:vpn_provider)
      client = %{mac: "aa:bb:cc:dd:ee:ff", ip: "192.168.1.100"}
      
      assert {:ok, mapping} = VPNManager.assign_client_to_vpn(client, provider)
      assert mapping.vpn_provider_id == provider.id
    end
  end
end
```

### Integration Tests

Test the full flow:
1. Create VPN provider
2. Assign client
3. Verify WireGuard interface creation
4. Check NFTables rules
5. Confirm traffic routing

## Deployment Checklist

- [ ] PostgreSQL database configured
- [ ] Age keys for credential encryption
- [ ] Systemd service for Phoenix app
- [ ] Caddy reverse proxy rules
- [ ] NFTables permissions for Phoenix user
- [ ] WireGuard kernel module loaded
- [ ] IP forwarding enabled
- [ ] Monitoring endpoints configured