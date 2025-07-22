# Router UI Implementation Tasks

## 🚀 Project Setup

- [x] Create Go project with Alpine.js and BadgerDB
- [x] Set up project structure
- [x] Add Tailwind CSS and DaisyUI configuration
- [x] Create NixOS module for router-ui service
- [ ] Configure systemd service with proper permissions (CAP_NET_ADMIN)
- [ ] Add Caddy reverse proxy configuration at `/router-ui`

## 🛠️ Development Environment

- [x] Create `just` commands for development workflow:
  - [x] `router-ui-dev` - Start development server
  - [x] `router-ui-setup` - Initial setup
  - [x] `router-ui-test` - Run tests
  - [x] `router-ui-build` - Build release
  - [x] `router-ui-watch` - Hot-reload development
  - [x] `router-ui-deploy` - Deploy to target host
- [x] Configure automatic Go dependency management
- [x] Set up CSS hot-reload with Tailwind
- [x] Fix static file MIME types
- [x] Handle BadgerDB lock cleanup

## 📦 Dependencies & Configuration

- [x] Set up Go module dependencies:
  - [x] `github.com/dgraph-io/badger/v4` for database
  - [x] `github.com/gorilla/mux` for routing
- [x] Configure web assets:
  - [x] Alpine.js for reactive UI
  - [x] Tailwind CSS for styling
  - [x] DaisyUI for UI components
- [x] Configure BadgerDB path for production (`/var/lib/router-ui/db`)
- [x] Set up age encryption for sensitive VPN credentials
- [x] Configure development environment with hot-reload
- [ ] Configure production environment

## 🗄️ Data Models

- [x] Define `VPNProvider` struct
  - [x] ID, Name, Type, Config (map)
  - [x] PublicKey, PrivateKey, PresharedKey (encrypted)
  - [x] Enabled, InterfaceName, Endpoint
  - [x] CreatedAt, UpdatedAt timestamps
- [x] Define `ClientVPNMapping` struct
  - [x] ID, ClientMAC, ClientIP, ClientHostname
  - [x] ProviderID, Enabled
  - [x] CreatedAt, UpdatedAt timestamps
- [x] Define `Client` struct
  - [x] MAC, IP, Hostname, Name
  - [x] DeviceType, Manufacturer, OS
  - [x] FirstSeen, LastSeen, Online status
  - [x] Tags, Notes, Static flag
- [x] Define `InterfaceStatus` struct
  - [x] Name, Connected status
  - [x] LastHandshake, BytesSent, BytesReceived
  - [x] ConnectedSince timestamp
- [ ] Define `SystemEvent` struct
  - [ ] ID, EventType, Severity, Message, Metadata
  - [ ] Timestamp

## 🎨 UI Components

- [x] Set up base layout with DaisyUI theme
- [x] Create navigation component with sections:
  - [x] VPN Providers
  - [x] Client Management
  - [x] Dashboard
  - [ ] System Logs
  - [ ] Settings
- [x] Implement theme switcher (light/dark/auto)
- [x] Add toast notifications for system events

## 🔌 VPN Manager Module

### Core Functionality
- [x] Create VPN handler with CRUD operations
- [x] Implement provider listing and management
- [x] Create WireGuard config generator
- [x] Implement secure credential storage with age
- [x] Add VPN provider validation (endpoint, keys)

### System Integration
- [x] Create WireGuard service for interface management
  - [x] Create/destroy WireGuard interfaces (using wg-quick)
  - [x] Apply WireGuard configurations
  - [x] Monitor interface status
- [x] Create NFT service for firewall rules
  - [x] Generate per-client routing rules
  - [x] Implement kill-switch rules
  - [x] Create NAT rules for VPN interfaces
- [x] Create routing service for policy-based routing
  - [x] Manage routing tables
  - [x] Create ip rules for marked packets
  - [ ] Handle route updates on VPN state changes

### Client Management
- [x] Create client discovery module
- [x] Implement ARP table scanning
- [x] Parse Kea DHCP lease files
- [x] Create client-to-VPN assignment API
- [x] Monitor network for client changes
- [x] Device type detection and classification
- [ ] Create client grouping functionality
- [ ] Add bulk operations (assign multiple clients)

## 📺 Web Pages

### Dashboard (`/`)
- [x] Create dashboard handler
- [x] Show system overview cards:
  - [x] Active VPN connections
  - [x] Connected clients count
  - [ ] Traffic statistics (partial - needs real data)
  - [ ] System health status (partial - needs real data)
- [ ] Add real-time updates via SSE

### VPN Providers (`/vpn`)
- [x] Create VPN providers page
- [x] Implement provider listing
- [x] Add provider creation form
- [x] Enable/disable toggle functionality
- [x] Show real-time connection status
- [x] Display traffic statistics
- [ ] Implement provider testing functionality
- [ ] Add import/export for WireGuard configs
- [ ] Show connection history

### Client Management (`/clients`)
- [x] Create clients page with enhanced data table
- [x] Show client list with device details
- [x] Display online/offline status
- [x] Show manufacturer and device type
- [x] Add client editing functionality
- [x] Implement VPN assignment
- [x] Add client statistics display
- [ ] Add search and filtering capabilities
- [ ] Add kill-switch toggle per client
- [ ] Create bulk selection and operations

### System Logs (`/logs`)
- [ ] Create system logs page
- [ ] Implement log filtering by severity
- [ ] Add search functionality
- [ ] Create log export feature
- [ ] Show VPN connection events

### Settings (`/settings`)
- [ ] Create settings page
- [ ] Add general system settings
- [ ] Configure monitoring integration
- [ ] Manage notification preferences
- [ ] Backup/restore functionality

## 🔧 Background Services

### VPN Health Monitor
- [x] Create VPN health monitoring goroutine
- [x] Implement periodic connection checks
- [x] Monitor WireGuard handshake times
- [x] Track bandwidth usage per VPN
- [ ] Send alerts on connection failures

### Client Discovery Service
- [x] Create client discovery service
- [x] Implement ARP/neighbor table scanner
- [x] Parse DHCP lease files (Kea & dnsmasq)
- [x] MAC vendor lookup with OUI database
- [x] Real-time client tracking
- [x] Device type classification
- [ ] mDNS/Bonjour discovery integration

### Metrics Collector
- [ ] Create metrics collection service
- [ ] Export VPN metrics to VictoriaMetrics
- [ ] Track per-client traffic statistics
- [ ] Monitor system resource usage
- [ ] Implement Prometheus-compatible endpoint

### System Event Logger
- [ ] Create event logging module
- [ ] Log all VPN state changes
- [ ] Track client assignment changes
- [ ] Record system errors and warnings
- [ ] Implement log rotation

## 🔒 Security

- [x] Implement Tailscale authentication middleware
- [ ] Add authorization for admin actions
- [ ] Create audit log for all changes
- [ ] Implement CSRF protection
- [ ] Add rate limiting for API endpoints
- [x] Secure credential encryption/decryption

## 🧪 Testing

### Unit Tests
- [ ] Test VPN provider CRUD operations
- [ ] Test WireGuard config generation
- [ ] Test NFT rule generation
- [ ] Test client discovery parsing
- [ ] Test credential encryption

### Integration Tests
- [ ] Test full VPN connection flow
- [ ] Test client assignment workflow
- [ ] Test failover scenarios
- [ ] Test kill-switch functionality

### System Tests
- [ ] Test with mock WireGuard interfaces
- [ ] Test NFT rule application
- [ ] Test monitoring integration
- [ ] Test backup/restore

## 📊 Monitoring Integration

- [ ] Create VictoriaMetrics scrape endpoint
- [ ] Export custom metrics:
  - [ ] `vpn_connection_status`
  - [ ] `vpn_client_count`
  - [ ] `vpn_bytes_sent/received`
  - [ ] `vpn_handshake_age`
- [ ] Create Grafana dashboard JSON
- [ ] Add dashboard panels:
  - [ ] VPN status overview
  - [ ] Traffic by VPN provider
  - [ ] Client distribution
  - [ ] Connection stability

## 🚢 Deployment

- [ ] Create Nix package definition
- [ ] Write NixOS module (`module.nix`)
- [ ] Configure systemd service:
  - [ ] User/group permissions
  - [ ] Capability requirements (CAP_NET_ADMIN)
  - [ ] Environment variables
  - [ ] Restart policy
- [ ] Add to router configuration.nix
- [ ] Configure Caddy reverse proxy
- [ ] Set up database directory creation
- [ ] Create backup strategy

## 📚 Documentation

- [x] Update architecture documentation for Go stack
- [ ] Write user guide for VPN management
- [ ] Document API endpoints
- [ ] Create troubleshooting guide
- [ ] Add inline help in UI
- [ ] Document backup/restore procedures

## ✅ Actually Working Features

- **Development Environment**: Full hot-reload setup with automatic rebuilds
- **Web Framework**: Go HTTP server with routing and middleware
- **UI Foundation**: Responsive layout with DaisyUI components and Alpine.js
- **Theme System**: Multiple themes with localStorage persistence
- **Database**: BadgerDB integration for key-value storage
- **Encryption**: Age encryption for VPN credentials
- **Static Assets**: Proper MIME type handling for CSS/JS files
- **Notifications**: Toast system for user feedback
- **VPN Management**: Full CRUD operations with WireGuard integration
- **Client Discovery**: ARP scanning, DHCP parsing, MAC vendor lookup
- **Background Services**: VPN monitoring, client discovery, status tracking
- **Real-time Updates**: Connection status monitoring
- **NFT Integration**: Firewall rule generation (structure ready)

## ⚠️ Remaining Mock Features

- **Dashboard Stats**: System health metrics need real data from /proc
- **Traffic Statistics**: Need to integrate with network-metrics-exporter
- **Real-time Updates**: SSE needs full implementation
- **Authentication**: Tailscale auth middleware needs testing
- **Client-to-VPN Routing**: NFT rules need to be applied when clients are assigned

## 🔜 Next Priority Tasks

1. **Complete Client-to-VPN Integration**:
   - Apply NFT rules when client VPN is assigned
   - Implement kill-switch functionality
   - Test traffic routing through VPN

2. **Production Deployment**:
   - Fix vendorHash in default.nix
   - Configure systemd service with CAP_NET_ADMIN
   - Set up Caddy reverse proxy
   - Test with real router environment

3. **Monitoring Integration**:
   - Create Prometheus metrics endpoint
   - Export VPN and client metrics
   - Update Grafana dashboards

4. **Testing**:
   - Add unit tests for core functionality
   - Mock system commands for testing
   - Test error handling paths

## 🎯 Future Enhancements

- [ ] Multi-WAN support with failover
- [ ] VPN provider auto-selection based on latency
- [ ] Traffic analytics and reporting dashboard
- [ ] Progressive Web App for mobile
- [ ] REST API for automation
- [ ] Webhook notifications
- [ ] IPv6 support
- [ ] DNS-over-VPN configuration
- [ ] Client bandwidth limits
- [ ] Time-based VPN schedules

## 🏆 Recent Accomplishments

### VPN Service Integration (Completed)
- Created `VPNService` managing VPN lifecycle and monitoring
- Integrated with existing `vpn.Manager` for WireGuard control
- Background goroutines monitor provider changes and interface status
- Proper startup/shutdown handling with graceful cleanup

### NFT Service Implementation (Completed)
- Created `NFTService` for managing nftables firewall rules
- Supports client-to-VPN routing rules generation
- Implements kill-switch functionality
- Manages policy-based routing tables

### Client Discovery System (Completed)
- Created comprehensive `ClientDiscoveryService`
- DHCP-agnostic design using ARP as primary source
- Supports Kea DHCP and dnsmasq lease parsing
- MAC vendor lookup with OUI database
- Real-time online/offline tracking
- Device type classification (computer, phone, tablet, IoT, etc.)

### Enhanced UI Features (Completed)
- Real-time VPN connection status with traffic statistics
- Client management with device details and icons
- Edit functionality for custom names and notes
- Statistics display (total clients, online count)
- Auto-refresh for live updates

### NixOS Integration (Completed)
- Created client database NixOS module
- Integrated into router configuration
- Prometheus metrics exporter for monitoring
- Shared client data across services