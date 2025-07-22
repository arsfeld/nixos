# Network Metrics Exporter - Enhancement Tasks

## 📊 REALISTIC ASSESSMENT: What's Actually Usable

### ✅ Production-Ready Features:
1. **Traffic Monitoring** - nftables integration works reliably
2. **Basic Device Discovery** - ARP table and reverse DNS lookups
3. **Static Client Configuration** - JSON file for known devices
4. **OUI Vendor Lookup** - Proper database with 607+ versions of updates

### ⚠️ Beta-Quality Features (Use with Caution):
1. **ARP-scan Discovery** - Works but needs monitoring for failures
2. **mDNS Discovery** - Limited but functional for basic device names
3. **Vendor-based Device Type** - Very basic inference from vendor strings

### ❌ NOT Ready for Production:
1. **Device Type Classification** - Too simplistic, many false positives
2. **Comprehensive Device Info** - Only tracks basic attributes
3. **Data Persistence** - Everything lost on restart
4. **Performance at Scale** - Untested with 100+ devices
5. **Error Recovery** - Basic error handling but no retry/backoff

### 🚫 Completely Missing:
1. **DHCP Fingerprinting** - Not implemented at all
2. **OS Detection** - No capability to identify operating systems
3. **Device Models** - No way to identify specific device models
4. **Historical Tracking** - No database, no trends, no history
5. **Configuration Management** - Most settings are hardcoded
6. **Testing** - Zero test coverage

## ⚠️ CRITICAL: Current Implementation Status

### What Actually Works:
- Basic traffic monitoring via nftables
- Simple device type inference from hostname patterns
- Basic client name resolution via reverse DNS
- Static client configuration file support
- Package builds successfully with all dependencies

### What's Been Added but is STILL NOT Production-Ready:
- **ARP-scan**: 
  - ✅ Error handling added (checks for binary, permissions, interface)
  - ✅ Uses TRAFFIC_INTERFACE environment variable
  - ⚠️ Still basic parsing with minimal validation
  - ⚠️ No retry logic or backoff
  - ⚠️ Cache has no size limits or advanced expiration
- **mDNS Discovery**: 
  - ✅ Basic error handling and panic recovery added
  - ✅ Tracks success/failure counts
  - ⚠️ Hardcoded service list (not configurable)
  - ⚠️ No TXT record parsing
  - ⚠️ No IPv6 support
  - ⚠️ Very limited device type inference
- **Vendor Detection**:
  - ✅ Integrated vendormap library (v0.0.607) with daily updates
  - ✅ Fallback from arp-scan to OUI database
  - ⚠️ Still using simplistic string matching for device type
  - ⚠️ No confidence scoring
  - ⚠️ Limited vendor-to-device-type mappings

### What's STILL Completely Missing:
- **Persistent storage** - All discovered data is lost on restart
- **Comprehensive device attributes** - Only tracking name, MAC, vendor, and basic device type
- **DHCP fingerprinting** - No DHCP option analysis
- **Device profiles** - No OS detection, model identification, or capability discovery
- **Proper database** - No SQLite/BoltDB for historical tracking
- **Configuration** - mDNS services, scan intervals, etc. are hardcoded
- **Tests** - Zero test coverage for any functionality
- **Metrics** - No discovery performance metrics, confidence scores, or detailed device info

## Current Status
The network-metrics-exporter is functional with basic device type detection based on hostname patterns and limited MAC OUI lookup.

### Recently Improved (But Still Incomplete)
- **ARP-scan integration**: Added error handling and uses environment variables correctly
- **mDNS discovery**: Added error handling and success tracking, but still limited
- **Vendor detection**: Now uses proper OUI database (vendormap v0.0.607) instead of hardcoded prefixes
- **Build system**: Fixed go.mod dependencies and vendor hash - package builds correctly

### Critical Issues REMAINING
1. **No persistent storage** - All discovered data is lost on restart
2. **Oversimplified device type inference** - Still using basic string matching instead of proper fingerprinting
3. **No comprehensive device information** - Still only tracking basic attributes (name, MAC, vendor, type)
4. **Limited configuration** - mDNS services, patterns, and intervals are hardcoded
5. **No tests** - Zero test coverage
6. **No advanced discovery** - Missing DHCP fingerprinting, SSDP/UPnP, behavioral analysis
7. **No confidence scoring** - All device type assignments are treated as certain

## Code Quality Assessment

### What's Good:
- Clean separation of discovery methods (ARP, mDNS)
- Proper use of goroutines for concurrent operations
- Mutex protection for shared data structures
- Structured logging of errors

### What Needs Work:
- **No abstraction** - Everything in main.go (1200+ lines)
- **No interfaces** - Hard to test or mock
- **Global state everywhere** - Makes testing impossible
- **Hardcoded values** - Magic numbers and strings throughout
- **No error types** - Just string errors, hard to handle programmatically
- **Memory leaks potential** - Caches grow without bounds
- **No graceful shutdown** - Discovery goroutines can't be stopped

## Requirements
- Use the existing network-metrics-exporter package (do NOT create separate packages like dhcp-fingerprint)
- Use proper databases for device fingerprinting and OUI lookups (not simplified custom implementations)
- Collect comprehensive device information beyond just device type:
  - Manufacturer/vendor name
  - Device model (if available)
  - Operating system (if detectable)
  - Hardware capabilities
  - Network capabilities (802.11 standards, etc.)

## IMMEDIATE PRIORITIES (Next Steps)

1. **Implement Persistent Storage** ⭐ HIGHEST PRIORITY:
   - Add BoltDB or SQLite for device database
   - Store device history and discovery timestamps
   - Implement proper device merging when data comes from multiple sources
   - Add startup recovery to reload known devices

2. **Enhance Device Information Collection**:
   - Expand ClientInfo struct to include vendor, model, OS, capabilities
   - Parse mDNS TXT records for additional device information
   - Add DHCP option parsing (even basic Option 60 vendor class)
   - Implement confidence scoring for device type inference

3. **Add Configuration Options**:
   - Make mDNS service list configurable via environment
   - Add scan interval configuration
   - Allow disabling specific discovery methods
   - Add device type pattern overrides

4. **Implement Basic Tests**:
   - Unit tests for device type inference
   - Tests for vendor lookup and OUI database
   - Mock arp-scan and mDNS responses for testing
   - Integration test with mock network data

## Implementation Priorities

1. **Use Existing Libraries/Databases**:
   - IEEE OUI database via github.com/klauspost/oui or similar
   - Fingerbank API or database for DHCP fingerprinting
   - Existing mDNS/Bonjour libraries for service discovery

2. **Data Model Enhancement**:
   - Expand ClientInfo struct to include all device attributes
   - Create proper database schema for persistent storage
   - Design metrics that expose comprehensive device information

3. **Integration Approach**:
   - All enhancements should be added to network-metrics-exporter
   - Maintain backward compatibility with existing metrics
   - Use configuration options to enable/disable features

## Phase 1: Quick Wins (Immediate)

### Enhanced DHCP Information Collection
- [ ] Parse Kea extended lease file format to extract vendor class identifiers (Option 60)
- [ ] Capture client-provided hostname (Option 12) vs assigned hostname
- [ ] Store DHCP options in client info structure
- [ ] Add vendor class to device type inference logic

### ARP-scan Integration
- [x] Add `arp-scan` to package dependencies in `module.nix` ✓
- [x] Create `runArpScan()` function ⚠️ **PARTIALLY COMPLETE**:
  - ✅ Uses TRAFFIC_INTERFACE environment variable
  - ✅ Checks if arp-scan binary exists
  - ✅ Handles permission and interface errors
  - ⚠️ No retry logic or exponential backoff
  - ⚠️ Basic output format assumptions
- [x] ARP-scan output parsing ⚠️ **BASIC BUT FUNCTIONAL**:
  - ✅ Validates IP addresses
  - ✅ Validates MAC address format
  - ⚠️ Only handles standard output format
  - ⚠️ No handling of IPv6 addresses
- [x] Update `getMacAddress()` to fall back to arp-scan cache ✓
- [x] Cache structure ⚠️ **MINIMAL**:
  - ✅ 5-minute scan interval prevents excessive scanning
  - ⚠️ No persistence across restarts
  - ⚠️ No cache size limits or LRU eviction

### mDNS/Avahi Discovery
- [x] Add zeroconf library dependency (github.com/grandcat/zeroconf) ✓
- [x] Create `discoverMDNS()` function ⚠️ **BASIC IMPLEMENTATION**:
  - ✅ UDP socket check before attempting discovery
  - ✅ Panic recovery and error counting
  - ✅ Success/failure tracking
  - ⚠️ Hardcoded service list (16 services)
  - ⚠️ No IPv6 support
  - ⚠️ Fixed 10-second timeout
- [x] mDNS name resolution ⚠️ **MINIMAL**:
  - ✅ Extracts instance name and hostname
  - ⚠️ No TXT record parsing
  - ⚠️ No handling of name conflicts
  - ⚠️ No priority between instance/hostname
- [x] Service type to device type mapping ⚠️ **VERY LIMITED**:
  - ✅ Basic mappings for common services
  - ⚠️ Only covers ~5 device categories
  - ⚠️ No confidence scoring
  - ⚠️ No extensibility
- [x] Update client names with mDNS discoveries ✓

## Phase 2: Advanced Discovery

### DHCP Fingerprinting
- [ ] Create DHCP packet capture using gopacket
- [ ] Extract DHCP parameter request lists and option orders
- [ ] Use existing fingerprint databases (e.g., Fingerbank API or local database)
- [ ] Store comprehensive device attributes:
  - Device type (computer, phone, IoT, etc.)
  - Operating system and version
  - Device manufacturer and model
  - Network capabilities
- [ ] Add confidence scoring to all attributes

### SSDP/UPnP Discovery
- [ ] Implement SSDP M-SEARCH multicast listener
- [ ] Parse SSDP responses for device info
- [ ] Extract device type from UPnP device descriptions
- [ ] Handle common IoT device SSDP signatures

### Enhanced MAC OUI Database
- [x] Integrated vendormap library (github.com/wimark/vendormap v0.0.607) ✅
- [x] Automatic fallback from arp-scan vendor to OUI database ✅
- [x] Full vendor name lookup, not just device type ✅
- [ ] Handle MAC address randomization detection
- [ ] Include vendor-specific device model mappings
- [ ] Add more sophisticated vendor-to-device-type inference

## Phase 3: Comprehensive Solution

### Unified Device Database
- [ ] Create persistent SQLite or BoltDB database for device info
- [ ] Store comprehensive device profiles:
  - MAC address (primary key)
  - IP address history
  - All discovered names/hostnames
  - Device type with confidence
  - Manufacturer/vendor
  - Device model
  - Operating system and version
  - Network capabilities (WiFi standards, etc.)
  - Discovery timestamps and sources
- [ ] Track discovery sources and confidence levels for each attribute
- [ ] Implement intelligent device merging logic
- [ ] Add manual override capability for all attributes
- [ ] Export detailed device metrics and attributes

### Behavioral Analysis
- [ ] Track DNS query patterns per device
- [ ] Analyze traffic patterns (streaming, IoT, etc.)
- [ ] Identify device sleep/wake patterns
- [ ] Classify based on connection destinations

### API Integration
- [ ] Add optional Fingerbank API support for device fingerprinting
- [ ] Integrate MAC vendor lookup APIs for enhanced OUI data
- [ ] Implement rate limiting and caching
- [ ] Handle API failures gracefully
- [ ] Add configuration for API keys
- [ ] Support offline database fallbacks

## Code Quality Improvements

### Testing
- [ ] Add unit tests for device type inference
- [ ] Create test fixtures for various device types
- [ ] Mock external command outputs
- [ ] Add integration tests with test network

### Performance
- [ ] Optimize client lookup with proper data structures
- [ ] Reduce ARP table parsing frequency
- [ ] Batch database writes
- [ ] Add metrics for exporter performance

### Configuration
- [ ] Make device type patterns configurable
- [ ] Add custom MAC OUI mappings option
- [ ] Allow disabling specific discovery methods
- [ ] Configure discovery intervals

## Documentation

- [ ] Document all device type detection methods
- [ ] Create device type pattern reference
- [ ] Add troubleshooting guide
- [ ] Include examples of manual overrides

## Metrics Currently Implemented

- [x] `client_traffic_bytes{direction,ip,client,device_type}` - Traffic counters
- [x] `client_traffic_rate_bps{direction,ip,client,device_type}` - Traffic rates
- [x] `client_active_connections{ip,client,device_type}` - Connection counts
- [x] `client_status{ip,client,device_type}` - Online/offline status
- [x] `network_clients_total` - Total known clients
- [x] `network_clients_online` - Online clients count
- [x] `network_clients_by_type{type}` - Clients grouped by device type

## Metrics TO BE ADDED

- [ ] `device_discovery_duration_seconds{method="arp|mdns|dhcp"}` - Track discovery performance
- [ ] `device_discovery_failures_total{method="arp|mdns|dhcp"}` - Track discovery failures
- [ ] `device_type_confidence{ip="x.x.x.x",confidence="0.0-1.0"}` - Confidence in device type classification
- [ ] `device_discovery_source{ip="x.x.x.x",source="dhcp|mdns|arp|manual"}` - Track how device was discovered
- [ ] `device_info{ip="x.x.x.x",mac="xx:xx:xx:xx:xx:xx",manufacturer="Apple",model="iPhone 15",os="iOS",device_type="phone"}` - Comprehensive device info (value=1)
- [ ] `device_capabilities{ip="x.x.x.x",wifi="802.11ac",bluetooth="5.0",ethernet="false"}` - Hardware/network capabilities