# Network Device Discovery Improvements

This document outlines better methods to discover device names and types in a network beyond basic DHCP hostname resolution.

## Current State

The router currently uses:
1. Basic DHCP hostname from Kea DHCP server
2. Reverse DNS lookup
3. Simple hostname pattern matching and MAC OUI lookup in `network-metrics-exporter`

## Improved Discovery Methods

### 1. Enhanced DHCP Information

#### Kea DHCP Advanced Options
Kea DHCP server can capture additional client information:

- **Option 60 (Vendor Class Identifier)**: Provides device type/vendor info
- **Option 12 (Hostname)**: Client-provided hostname  
- **Option 61 (Client Identifier)**: Unique client identifier
- **Option 77 (User Class)**: Additional classification data
- **Option 82 (Relay Agent Information)**: Switch port info if available

```nix
# Example Kea configuration to capture vendor class
services.kea.dhcp4.settings = {
  # Enable option data storage
  option-def = [
    {
      name = "vendor-class-identifier";
      code = 60;
      type = "string";
    }
  ];
  
  # Log vendor class in leases
  lease-database = {
    type = "memfile";
    persist = true;
    name = "/var/lib/kea/kea-leases4.csv";
    # Extended info includes options
    extended-info-tables = true;
  };
};
```

### 2. mDNS/Avahi Discovery

Many devices broadcast their services and names via mDNS:

```nix
# Enable Avahi daemon on router
services.avahi = {
  enable = true;
  reflector = true;  # Reflect between interfaces
  interfaces = ["br-lan"];
  
  # Browse for devices
  browseProtocols = ["IPv4" "IPv6"];
  browseDomains = ["local"];
};

# Tools for mDNS discovery:
# - avahi-browse -a  # List all services
# - avahi-resolve -n hostname.local  # Resolve mDNS names
```

### 3. SSDP/UPnP Discovery

Smart devices often announce via SSDP (Simple Service Discovery Protocol):

```bash
# Example SSDP discovery script
#!/usr/bin/env bash
# Send M-SEARCH to discover UPnP devices
echo -ne "M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 3\r\nST: ssdp:all\r\n\r\n" | \
  socat - UDP-DATAGRAM:239.255.255.250:1900,broadcast

# Parse responses for device info
```

### 4. LLDP (Link Layer Discovery Protocol)

For network equipment and managed devices:

```nix
# Install LLDP daemon
services.lldpd = {
  enable = true;
  interfaces = ["br-lan"];
};

# Query LLDP neighbors
# lldpcli show neighbors
```

### 5. MAC OUI Database Enhancement

Use comprehensive OUI databases:

```nix
# Use ieee-data package for full OUI database
environment.systemPackages = [ pkgs.ieee-data ];

# Alternative: Use Fingerbank API for MAC lookup
# https://api.fingerbank.org/api/v2/oui/{mac_prefix}
```

### 6. Active Scanning Tools

```nix
environment.systemPackages = with pkgs; [
  nmap          # Port scanning and OS detection
  arp-scan      # ARP-based device discovery
  netdiscover   # Active/passive ARP reconnaissance
];

# Example nmap device detection
# nmap -sn 192.168.10.0/24 --script smb-os-discovery
```

### 7. DHCP Fingerprinting with Fingerbank

Fingerbank provides device identification based on DHCP fingerprints:

```go
// Example integration with Fingerbank API
type FingerbankResponse struct {
    Device struct {
        Name       string `json:"name"`
        Parent     string `json:"parent"`  
        Type       string `json:"device_type"`
        Confidence int    `json:"confidence"`
    } `json:"device"`
}

func queryFingerbank(dhcpOptions string, apiKey string) (*FingerbankResponse, error) {
    // POST to https://api.fingerbank.org/api/v2/combinations/interrogate
    // with DHCP fingerprint data
}
```

### 8. NetBIOS Name Service

For Windows devices:

```bash
# Query NetBIOS names
nmblookup -A 192.168.10.5

# Or use nbtscan
nbtscan 192.168.10.0/24
```

### 9. SNMP Discovery

For managed devices:

```nix
# SNMP tools
environment.systemPackages = [ pkgs.net-snmp ];

# Query device info
# snmpwalk -v2c -c public 192.168.10.5 sysDescr
```

### 10. Behavioral Analysis

Identify devices by network behavior patterns:
- DNS query patterns (streaming devices, IoT devices)
- Connection patterns (NTP servers used, cloud endpoints)
- Traffic volume and timing patterns

## Implementation Strategy

### Phase 1: Enhanced DHCP Collection
1. Configure Kea to collect vendor class and other options
2. Modify network-metrics-exporter to parse extended lease data
3. Store device attributes in persistent database

### Phase 2: Passive Discovery
1. Enable mDNS reflection and monitoring
2. Implement SSDP listener
3. Parse discovery protocols for device info

### Phase 3: Active Discovery
1. Periodic nmap scans for new devices
2. LLDP neighbor discovery
3. NetBIOS/SNMP queries for capable devices

### Phase 4: Fingerprinting Integration
1. Integrate Fingerbank API or local database
2. Collect DHCP fingerprints from packet capture
3. Match against fingerprint database

### Phase 5: Machine Learning
1. Collect behavioral data over time
2. Train model to identify device types
3. Improve accuracy with user feedback

## Example Enhanced Network Metrics Exporter

```go
type DeviceInfo struct {
    IP              string
    MAC             string
    Hostname        string
    DeviceType      string
    Vendor          string
    Model           string
    OS              string
    Services        []string
    LastSeen        time.Time
    DiscoverySource string  // dhcp, mdns, ssdp, lldp, etc.
    Confidence      float64
}

// Discovery methods
func (d *DeviceDiscovery) DiscoverDevice(ip string) *DeviceInfo {
    device := &DeviceInfo{IP: ip}
    
    // Try multiple discovery methods
    d.tryDHCPInfo(device)
    d.tryMDNS(device)
    d.trySSDPP(device)
    d.tryLLDP(device)
    d.tryNetBIOS(device)
    d.tryFingerbank(device)
    
    // Merge and prioritize results
    device.DeviceType = d.inferDeviceType(device)
    
    return device
}
```

## NixOS Module Example

```nix
{ config, lib, pkgs, ... }:

{
  options.services.network-device-discovery = {
    enable = lib.mkEnableOption "network device discovery service";
    
    methods = {
      dhcp = lib.mkEnableOption "DHCP-based discovery" // { default = true; };
      mdns = lib.mkEnableOption "mDNS/Avahi discovery" // { default = true; };
      ssdp = lib.mkEnableOption "SSDP/UPnP discovery" // { default = true; };
      lldp = lib.mkEnableOption "LLDP discovery";
      netbios = lib.mkEnableOption "NetBIOS discovery";
      snmp = lib.mkEnableOption "SNMP discovery";
      fingerbank = lib.mkEnableOption "Fingerbank integration";
    };
    
    fingerbankApiKey = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Fingerbank API key for device fingerprinting";
    };
  };
  
  config = lib.mkIf config.services.network-device-discovery.enable {
    # Implementation here
  };
}
```

## Security Considerations

1. **Privacy**: Device discovery can reveal sensitive information
2. **Network Load**: Active scanning can impact network performance
3. **Access Control**: Limit discovery to authorized networks
4. **Data Storage**: Encrypt stored device information
5. **API Keys**: Protect external API credentials

## Existing Tools

### Open Source
- **ntopng**: Network traffic analysis with device discovery
- **PacketFence**: NAC with Fingerbank integration  
- **OpenWrt's LuCI**: Has device tracking features
- **Home Assistant**: Excellent device discovery implementation

### Commercial
- **Lansweeper**: Comprehensive IT asset discovery
- **ManageEngine OpUtils**: Network scanner
- **SolarWinds Network Discovery**: Enterprise tool

## References

1. [Fingerbank API Documentation](https://api.fingerbank.org/api_doc/)
2. [IETF RFC 2131 - DHCP](https://www.ietf.org/rfc/rfc2131.txt)
3. [IEEE 802.1AB - LLDP Standard](https://standards.ieee.org/standard/802_1AB-2016.html)
4. [SSDP Protocol Specification](https://datatracker.ietf.org/doc/html/draft-cai-ssdp-v1-03)
5. [Avahi mDNS/DNS-SD Documentation](https://avahi.org/doxygen/html/)