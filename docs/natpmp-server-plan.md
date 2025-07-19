# NAT-PMP Server Implementation Plan

## Overview
A lightweight Go-based NAT-PMP server designed specifically for NixOS routers using nftables.

**Status**: ✅ Implementation complete and functional (deadlock issue fixed)

## Architecture

### Core Components

1. **NAT-PMP Protocol Handler**
   - Listen on UDP port 5351 (configurable)
   - Parse NAT-PMP protocol messages
   - Generate appropriate responses
   - Handle protocol version 0

2. **State Manager**
   - Store active mappings in systemd state directory (`/var/lib/natpmp-server/`)
   - Persist mappings across restarts using JSON format
   - Track mapping lifetimes and handle expiration
   - Atomic file operations to prevent corruption

3. **nftables Integration**
   - Execute nft commands directly
   - Use table/chain names from configuration
   - Add DNAT rules for port mappings
   - Clean up rules on expiration or shutdown

4. **Configuration System**
   - Command-line flags for all options
   - Optional configuration file support (TOML/JSON)
   - Environment variable overrides

## Configuration Options

```go
type Config struct {
    // Network settings
    ListenInterface string // default: "br-lan"
    ListenPort      int    // default: 5351
    ExternalInterface string // default: "eth0"
    
    // nftables settings
    NatTable        string // default: "nat"
    NatChain        string // default: "NATPMP"
    FilterTable     string // default: "filter"
    FilterChain     string // default: "NATPMP"
    
    // Security settings
    AllowedPorts    []PortRange // default: 1024-65535
    MaxMappingsPerIP int        // default: 100
    DefaultLifetime  int        // default: 3600 seconds
    MaxLifetime      int        // default: 86400 seconds
    
    // Operational settings
    StateDir        string // default: "/var/lib/natpmp-server"
    LogLevel        string // default: "info"
    CleanupInterval int    // default: 60 seconds
}

type PortRange struct {
    Start uint16
    End   uint16
}
```

## Implementation Details

### 1. Main Loop
```go
func main() {
    // Parse configuration
    config := parseConfig()
    
    // Initialize state manager
    stateManager := NewStateManager(config.StateDir)
    stateManager.LoadState()
    
    // Initialize nftables manager
    nftManager := NewNFTablesManager(config)
    
    // Start cleanup goroutine
    go cleanupExpiredMappings(stateManager, nftManager)
    
    // Start NAT-PMP server
    server := NewNATPMPServer(config, stateManager, nftManager)
    server.ListenAndServe()
}
```

### 2. NAT-PMP Protocol Implementation

Supported operations:
- **Opcode 0**: Get external IP address
- **Opcode 1**: Map UDP port
- **Opcode 2**: Map TCP port

Message format handling:
- Parse 2-byte version and opcode
- Validate request format
- Generate response with result code
- Handle lifetime negotiations

### 3. State Management

State file format (`/var/lib/natpmp-server/mappings.json`):
```json
{
  "mappings": [
    {
      "internal_ip": "10.1.1.100",
      "internal_port": 8080,
      "external_port": 8080,
      "protocol": "tcp",
      "lifetime": 3600,
      "created_at": "2024-01-20T10:00:00Z",
      "expires_at": "2024-01-20T11:00:00Z"
    }
  ]
}
```

### 4. nftables Rule Management

Rule format:
```bash
# Add mapping
nft add rule ip nat NATPMP tcp dport 8080 dnat to 10.1.1.100:8080

# Delete mapping (using handle)
nft delete rule ip nat NATPMP handle 42
```

Store rule handles in state for cleanup.

## NixOS Module Design

```nix
{ config, lib, pkgs, ... }:

{
  options.services.natpmp-server = {
    enable = mkEnableOption "NAT-PMP server";
    
    listenInterface = mkOption {
      type = types.str;
      default = "br-lan";
      description = "Interface to listen for NAT-PMP requests";
    };
    
    externalInterface = mkOption {
      type = types.str;
      description = "External interface for NAT";
    };
    
    allowedPortRanges = mkOption {
      type = types.listOf (types.submodule {
        options = {
          from = mkOption { type = types.int; };
          to = mkOption { type = types.int; };
        };
      });
      default = [{ from = 1024; to = 65535; }];
    };
    
    maxMappingsPerClient = mkOption {
      type = types.int;
      default = 100;
    };
  };
  
  config = mkIf config.services.natpmp-server.enable {
    systemd.services.natpmp-server = {
      description = "NAT-PMP Server";
      after = [ "network.target" "nftables.service" ];
      wantedBy = [ "multi-user.target" ];
      
      serviceConfig = {
        ExecStart = "${pkgs.natpmp-server}/bin/natpmp-server ${escapeShellArgs flags}";
        StateDirectory = "natpmp-server";
        Restart = "always";
        RestartSec = "5s";
        
        # Security
        DynamicUser = true;
        AmbientCapabilities = [ "CAP_NET_ADMIN" ];
        CapabilityBoundingSet = [ "CAP_NET_ADMIN" ];
        PrivateDevices = true;
        ProtectHome = true;
        ProtectSystem = "strict";
      };
    };
    
    networking.firewall.allowedUDPPorts = [ 5351 ];
  };
}
```

## Implementation Phases

### Phase 1: Core Protocol (MVP) ✅
- [x] Basic NAT-PMP protocol parsing
- [x] Get external IP operation
- [x] Simple in-memory state
- [x] Basic nftables integration
- [x] Command-line configuration

### Phase 2: Persistence & Reliability ✅
- [x] State persistence to disk
- [x] Mapping expiration handling
- [x] Graceful shutdown with cleanup
- [x] Reload without dropping mappings
- [x] Better error handling

### Phase 3: Security & Features ✅
- [x] Port range restrictions
- [x] Per-client limits
- [ ] Prometheus metrics endpoint (future)
- [ ] Configuration file support (not needed - NixOS handles config)
- [ ] IPv6 support (NAT-PMP v2) (future)

### Phase 4: NixOS Integration ✅
- [x] Package for nixpkgs
- [x] NixOS module
- [ ] Integration tests (broken due to infinite recursion in test framework)
- [x] Documentation
- [x] Deadlock fix deployed and tested in production

## Testing Strategy

1. **Unit tests**:
   - Protocol parsing/generation
   - State management
   - Configuration parsing

2. **Integration tests**:
   - nftables rule creation/deletion
   - State persistence
   - Concurrent client handling

3. **System tests**:
   - Full NixOS VM test
   - Multiple clients
   - Restart/reload scenarios

## Security Considerations

1. **Input validation**:
   - Validate all protocol fields
   - Prevent integer overflows
   - Limit request rate per client

2. **Resource limits**:
   - Maximum mappings per IP
   - Maximum total mappings
   - Reasonable lifetime limits

3. **Privilege separation**:
   - Run as non-root with CAP_NET_ADMIN
   - Use systemd security features
   - Minimal filesystem access

## Error Handling

1. **Protocol errors**: Return appropriate NAT-PMP error codes
2. **System errors**: Log and continue operation
3. **nftables errors**: Rollback state on failure
4. **State corruption**: Validate and recover or reset

## Monitoring

- Systemd journal integration ✅
- Optional metrics endpoint (future)
- State file for debugging ✅
- Health check endpoint (via systemd status) ✅

## Implementation Notes

### Key Decisions Made
1. **No configuration file**: NixOS module handles all configuration declaratively
2. **Direct nftables integration**: Uses exec to call `nft` commands for simplicity
3. **JSON state format**: Simple and reliable for persistence
4. **Separate chains**: Uses NATPMP_DNAT chain to avoid conflicts with other services

### Lessons Learned
1. **Service dependencies**: Must include `nftables` in service PATH
2. **Port conflicts**: Need to disable miniupnpd if using custom NAT-PMP server
3. **Interface detection**: Use actual interface names from router configuration
4. **State directory**: Created automatically by systemd with StateDirectory directive
5. **Test framework issues**: NixOS test framework has infinite recursion when modules reference `self`

### Known Issues (Fixed)
1. **~~Critical Deadlock Bug~~ (FIXED)**: The NAT-PMP server had a critical deadlock issue that has been resolved.
   - **Original Issue**: Goroutines would deadlock when `SaveState()` tried to acquire a read lock while `AddMapping()` held a write lock
   - **Root Cause**: `SaveState()` was incorrectly trying to acquire a read lock when called from functions that already held write locks
   - **Solution**: Created an internal `saveStateInternal()` function that doesn't acquire locks, to be used when already holding a lock
   - **Status**: Fixed and tested - the server now correctly handles port mappings without deadlocks

2. **NixOS Router Tests**: The router integration tests are currently broken due to infinite recursion when the monitoring module references `self`. This prevents full automated testing of NAT-PMP functionality.
3. **Limited Testing**: While basic functionality works (info requests, port mapping creation), the full NAT-PMP protocol implementation hasn't been thoroughly tested under various conditions.
4. **State Persistence**: Not fully tested across service restarts and system reboots
5. **Concurrent Mappings**: Behavior under high load with many concurrent clients is untested

### Future Improvements
1. **Metrics export**: Add Prometheus metrics for monitoring port mappings
2. **Rate limiting**: Implement per-client request rate limiting
3. **IPv6 support**: Add PCP (Port Control Protocol) for IPv6
4. **Web UI**: Simple status page showing active mappings

## Usage

### Deployment
```nix
# In router configuration
services.natpmp-server = {
  enable = true;
  externalInterface = config.router.interfaces.wan;
  listenInterface = "br-lan";
  maxMappingsPerClient = 50;
};
```

### Testing
```bash
# Test from LAN client
python3 natpmp-test-client.py 192.168.10.1 info
python3 natpmp-test-client.py 192.168.10.1 map 8080 8080 tcp 3600
```

### Monitoring
```bash
# Check service status
systemctl status natpmp-server

# View logs
journalctl -u natpmp-server -f

# Check nftables rules
nft list chain ip nat NATPMP_DNAT
```

## Metrics and Observability

### Current State
The NAT-PMP server currently provides basic observability through:
- **Systemd journal logs**: All operations are logged with appropriate detail levels
- **Service status**: Standard systemd service health monitoring
- **nftables inspection**: Manual checking of active port mappings via `nft` commands

### Proposed Metrics Implementation

#### Prometheus Metrics
Future implementation should expose metrics on a separate HTTP endpoint (e.g., `:9100/metrics`):

```go
// Proposed metrics
natpmp_requests_total{type="info|map_tcp|map_udp", result="success|error"}
natpmp_active_mappings{protocol="tcp|udp"}
natpmp_mappings_created_total{protocol="tcp|udp"}
natpmp_mappings_expired_total{protocol="tcp|udp"}
natpmp_mappings_deleted_total{protocol="tcp|udp", reason="expired|shutdown|error"}
natpmp_client_mappings{client_ip="..."} // Per-client mapping count
natpmp_port_range_usage{range="1024-65535"} // Percentage of ports in use
natpmp_state_operations{operation="load|save", result="success|error"}
natpmp_nftables_operations{operation="add|delete", result="success|error"}
```

#### Integration with Router Monitoring
The metrics should integrate with the existing router monitoring stack:
1. Export to Prometheus node exporter text files
2. Create Grafana dashboard for NAT-PMP monitoring
3. Set up alerts for:
   - High port usage (>80% of allowed range)
   - Failed nftables operations
   - State persistence errors
   - Unusual client behavior (too many mappings)

#### Implementation Approach
```go
// Add metrics package
import "github.com/prometheus/client_golang/prometheus"

// Initialize collectors in main()
var (
    requestsTotal = prometheus.NewCounterVec(...)
    activeMappings = prometheus.NewGaugeVec(...)
    // ... other metrics
)

// Update metrics throughout the code
requestsTotal.WithLabelValues("info", "success").Inc()
activeMappings.WithLabelValues("tcp").Set(float64(count))
```

### Debugging and Troubleshooting

#### Critical Deadlock Issue (Current)
The service is experiencing a deadlock that prevents any port mappings from being created:

```bash
# Symptoms visible in logs:
journalctl -u natpmp-server -f
# Shows requests getting stuck at:
# "Checking mapping count for IP X.X.X.X"
# No further processing occurs

# Stack trace shows futex wait:
pgrep natpmp-server | xargs -I {} cat /proc/{}/stack
# Shows: futex_wait_queue (indicating deadlock)

# Goroutines accumulate but never complete:
# Multiple "handleRequest goroutine started" without corresponding "finished"
```

#### General Debugging Commands
For immediate debugging needs:
```bash
# Check current mappings
journalctl -u natpmp-server | grep "Mapping created"

# Monitor in real-time
watch -n 1 'nft list chain ip nat NATPMP_DNAT | grep -c "dnat to"'

# Debug state file
cat /var/lib/natpmp-server/mappings.json | jq .

# Check metrics endpoint
curl -s http://localhost:9333/metrics | grep natpmp
```