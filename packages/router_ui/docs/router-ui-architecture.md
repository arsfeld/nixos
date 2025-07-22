# Router UI Architecture

## Overview

Router UI is a Go-based web application that provides a modern interface for managing router services. Built with Go, Alpine.js, and DaisyUI, it offers a responsive and intuitive management interface for various router functionalities.

## Tech Stack

- **Backend**: Go with standard library HTTP server
- **Frontend**: Alpine.js with Tailwind CSS and DaisyUI
- **Database**: BadgerDB (embedded key-value store for high performance)
- **Real-time**: Server-Sent Events (SSE) for live updates
- **Process Management**: Go routines and channels for concurrency

## Project Structure

Router UI is packaged as an independent NixOS module located in `packages/router_ui/` with the following structure:

```
packages/router_ui/
├── default.nix          # Nix package definition
├── module.nix           # NixOS module definition
├── docs/                # Documentation
│   ├── router-ui-architecture.md
│   └── vpn-manager-implementation.md
├── go.mod               # Go module definition
├── go.sum               # Go dependencies lockfile
├── main.go              # Application entry point
├── config/              # Configuration
│   └── config.go        # Configuration structures
├── internal/
│   ├── server/          # HTTP server implementation
│   │   ├── server.go    # Main server setup
│   │   ├── handlers/    # HTTP handlers
│   │   └── middleware/  # HTTP middleware
│   ├── db/              # BadgerDB interface
│   │   └── db.go        # Database operations
│   └── modules/         # Feature modules
│       ├── vpn/         # VPN manager
│       ├── clients/     # Client manager
│       └── monitoring/  # Monitoring integration
├── web/                 # Frontend assets
│   ├── static/          # Static files
│   │   ├── css/         # Compiled CSS
│   │   └── js/          # Alpine.js components
│   ├── templates/       # HTML templates
│   └── src/             # Source files
│       ├── css/
│       │   └── app.css  # Tailwind CSS imports
│       └── js/
│           └── app.js   # Alpine.js initialization
└── TASK.md              # Implementation checklist
```

## Core Modules

### 1. VPN Manager Module

Located in `internal/modules/vpn/`, this module handles:

- VPN provider configuration management
- Client-to-VPN mapping
- WireGuard interface lifecycle
- Traffic routing rules generation

### 2. Client Manager Module

Located in `internal/modules/clients/`, this module provides:

- DHCP client discovery and tracking
- Client device identification
- Network statistics per client
- Client grouping and policies

### 3. Monitoring Module

Located in `internal/modules/monitoring/`, this module integrates with:

- VictoriaMetrics for metrics collection
- System resource monitoring
- VPN connection health checks
- Alert management

## VPN Manager Module Design

### Data Models

```go
// VPN Provider Configuration
type VPNProvider struct {
    ID            string            `json:"id"`
    Name          string            `json:"name"`
    Type          string            `json:"type"` // "wireguard", "openvpn"
    Config        map[string]string `json:"config"` // Provider-specific configuration
    Enabled       bool              `json:"enabled"`
    InterfaceName string            `json:"interface_name"` // e.g., "wg-pia"
    Endpoint      string            `json:"endpoint"`
    PublicKey     string            `json:"public_key"`
    PrivateKey    string            `json:"private_key"`
    PresharedKey  string            `json:"preshared_key"`
    CreatedAt     time.Time         `json:"created_at"`
    UpdatedAt     time.Time         `json:"updated_at"`
}

// Client to VPN Mapping
type ClientVPNMapping struct {
    ID             string    `json:"id"`
    ClientMAC      string    `json:"client_mac"`
    ClientIP       string    `json:"client_ip"`
    ClientHostname string    `json:"client_hostname"`
    ProviderID     string    `json:"provider_id"`
    Enabled        bool      `json:"enabled"`
    CreatedAt      time.Time `json:"created_at"`
    UpdatedAt      time.Time `json:"updated_at"`
}
```

### Core Services

1. **VPN Supervisor** - Manages WireGuard interface processes using goroutines
2. **NFT Rule Generator** - Generates nftables rules for traffic isolation
3. **Client Discovery** - Integrates with Kea DHCP for client detection
4. **Health Monitor** - Monitors VPN connection status

### Frontend Components

```html
<!-- Main VPN Manager Page -->
<div x-data="vpnManager()" class="container mx-auto p-4">
  <!-- VPN Provider List -->
  <div class="card bg-base-100 shadow-xl mb-4">
    <div class="card-body">
      <h2 class="card-title">VPN Providers</h2>
      <div class="overflow-x-auto">
        <table class="table table-zebra">
          <template x-for="provider in providers">
            <tr>
              <td x-text="provider.name"></td>
              <td x-text="provider.type"></td>
              <td>
                <input type="checkbox" class="toggle toggle-primary" 
                       :checked="provider.enabled"
                       @change="toggleProvider(provider.id)">
              </td>
            </tr>
          </template>
        </table>
      </div>
    </div>
  </div>
  
  <!-- Client Mapping List -->
  <div class="card bg-base-100 shadow-xl">
    <div class="card-body">
      <h2 class="card-title">Client VPN Mappings</h2>
      <div x-show="clients.length > 0">
        <!-- Client mapping interface -->
      </div>
    </div>
  </div>
</div>

<script>
function vpnManager() {
  return {
    providers: [],
    clients: [],
    async init() {
      // Load initial data
      await this.fetchProviders();
      await this.fetchClients();
      // Setup SSE for real-time updates
      this.setupEventSource();
    },
    // Component methods...
  }
}
</script>
```

## Integration with NixOS

### Go Service Definition

The Go application runs as a systemd service with:

- Automatic restart on failure
- HTTP server on port 4000 (configurable)
- Integration with existing router services
- Proper file permissions for system interaction

### System Integration Points

1. **NFTables Integration**
   - Direct rule injection via `nft` commands
   - Atomic rule updates
   - Persistent rule storage

2. **WireGuard Management**
   - Uses `wg` and `ip` commands
   - Systemd service integration
   - Key management via age encryption

3. **DHCP Integration**
   - Monitors Kea lease file changes
   - Subscribes to DHCP events
   - Maintains client database

## Security Considerations

1. **Authentication**
   - Tailscale-based authentication
   - Local network access only
   - Optional basic auth for LAN access

2. **Authorization**
   - Role-based access control
   - Audit logging for all changes
   - Secure storage of VPN credentials

3. **Network Isolation**
   - Runs in isolated network namespace
   - Minimal system permissions
   - Sandboxed file access

## Deployment

The application is packaged as a NixOS module that:

1. Builds the Go binary
2. Creates necessary directories and permissions
3. Configures systemd service
4. Sets up reverse proxy rules in Caddy
5. Integrates with monitoring stack

### Usage in NixOS Configuration

To use Router UI in your router configuration:

```nix
# In hosts/router/configuration.nix or a dedicated service file
{ pkgs, ... }:

{
  imports = [
    ../../packages/router_ui/module.nix
  ];
  
  services.router-ui = {
    enable = true;
    port = 4000;
    environmentFile = "/run/secrets/router-ui-env";
  };
}
```

## Future Enhancements

1. **Multi-WAN Support** - Load balancing across multiple VPN providers
2. **Traffic Analytics** - Per-client bandwidth monitoring
3. **DNS Integration** - VPN-specific DNS servers
4. **Mobile App** - Progressive Web App for mobile management
5. **Backup/Restore** - Configuration export/import functionality