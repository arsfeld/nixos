# Comprehensive Device Classification Strategy

## Current State
The network-metrics-exporter currently uses:
- `github.com/wimark/vendormap` - Daily-updated OUI vendor database
- Basic device type inference from hostname patterns
- Simple vendor-based classification

## Production-Ready Solutions for Enhanced Classification

### 1. Enhanced OUI-Based Classification

#### wimark/vendormap (Currently Used)
- **Pros**: Daily updates, zero API calls, fully offline
- **Cons**: Only provides vendor name, no device type
- **Best for**: Basic vendor identification

#### klauspost/oui
- **Pros**: Vendor name + address + country, can run as microservice
- **Cons**: Requires manual database updates
- **Best for**: When you need vendor location data

### 2. Advanced Device Fingerprinting

#### Fingerbank API (via hslatman/fingerbank-go)
- **Pros**: 
  - Comprehensive device identification (type, OS, brand, model)
  - Uses DHCP fingerprints + MAC + User-Agent
  - 99%+ accuracy for known devices
  - Free tier: 300 req/hr, 1M/month
- **Cons**: 
  - Requires API key
  - Network dependency
  - Rate limited
- **Best for**: Production environments needing accurate device classification

#### Implementation Example:
```go
import "github.com/hslatman/fingerbank-go"

func enhancedDeviceClassification(ip, mac, dhcpFingerprint string) (deviceType, brand, model string) {
    // First try local vendormap (offline)
    vendor := vendormap.MACVendor(mac)
    
    // Then try Fingerbank for detailed classification
    client := fingerbank.NewClient(apiKey, fingerbank.WithCache(cache))
    params := &fingerbank.InterrogateParameters{
        MAC: mac,
        DHCPFingerprint: dhcpFingerprint,
    }
    
    resp, err := client.Interrogate(params)
    if err == nil && resp.Device != nil {
        return resp.Device.Type, resp.Device.Brand, resp.Device.Model
    }
    
    // Fallback to vendor-based inference
    return inferFromVendor(vendor), vendor, "unknown"
}
```

### 3. Multi-Source Classification Strategy

#### Priority Order:
1. **Static Database** - Known devices with manual classification
2. **DHCP Hostname** - Often contains device type hints
3. **Fingerbank API** - When DHCP fingerprint available
4. **mDNS/SSDP** - Service types reveal device category
5. **OUI Vendor** - Basic vendor identification
6. **Fallback** - Generic device type from patterns

### 4. Device Type Categories

Based on research, use these standard categories:
- `phone` - Mobile phones
- `tablet` - Tablets
- `laptop` - Portable computers
- `desktop` - Desktop computers
- `server` - Servers
- `printer` - Printers/scanners
- `media` - TVs, streaming devices, speakers
- `gaming` - Game consoles
- `iot` - Smart home devices, sensors
- `network` - Routers, switches, APs
- `storage` - NAS devices
- `camera` - Security cameras
- `wearable` - Smartwatches, fitness trackers
- `appliance` - Smart appliances
- `unknown` - Unclassified

### 5. Implementation Plan

#### Phase 1: Enhance Current System
- Improve vendor-to-type mapping with comprehensive rules
- Add DHCP fingerprint capture (Option 55)
- Create static device database with known MACs

#### Phase 2: Integrate Fingerbank
- Add fingerbank-go client
- Implement caching layer (24hr TTL)
- Rate limit management (300/hr)
- Fallback to local when API unavailable

#### Phase 3: Machine Learning Enhancement
- Collect network behavior patterns
- Train local classifier for unknown devices
- Use packet sizes, ports, protocols as features

### 6. DHCP Fingerprint Capture

Add to Kea DHCP configuration:
```json
{
  "Dhcp4": {
    "hooks-libraries": [{
      "library": "/usr/lib/kea/hooks/libdhcp_lease_cmds.so",
      "parameters": {
        "record-fingerprint": true
      }
    }]
  }
}
```

Capture in Go:
```go
// Parse DHCP Option 55 (Parameter Request List)
func extractDHCPFingerprint(packet []byte) string {
    // Option 55 contains requested DHCP options
    // Format: comma-separated list like "1,15,3,6,44,46,47,31,33,121,249,43"
    // This fingerprint is unique per OS/device type
}
```

### 7. Example Enhanced Classification

```go
func classifyDevice(ip, mac string) DeviceInfo {
    // 1. Check static database
    if device, ok := staticDevices[mac]; ok {
        return device
    }
    
    // 2. Check DHCP hostname
    hostname := getKeaHostname(ip, mac)
    if deviceType := inferFromHostname(hostname); deviceType != "unknown" {
        return DeviceInfo{Type: deviceType, Name: hostname}
    }
    
    // 3. Try Fingerbank (if DHCP fingerprint available)
    if fingerprint := getDHCPFingerprint(mac); fingerprint != "" {
        if device := queryFingerbank(mac, fingerprint); device != nil {
            return *device
        }
    }
    
    // 4. Check mDNS/SSDP cache
    if mdnsDevice := getMDNSDevice(ip); mdnsDevice != nil {
        return DeviceInfo{
            Type: inferFromService(mdnsDevice.Service),
            Name: mdnsDevice.Instance,
        }
    }
    
    // 5. OUI vendor lookup
    vendor := vendormap.MACVendor(mac)
    deviceType := inferFromVendor(vendor)
    
    // 6. Generate friendly name
    name := fmt.Sprintf("%s-%s", vendor, mac[12:17])
    
    return DeviceInfo{
        Type: deviceType,
        Name: name,
        Vendor: vendor,
    }
}
```

### 8. Vendor-to-Type Mapping

```go
var vendorDeviceTypes = map[string]string{
    // Phones
    "apple": "phone", // Could be laptop, needs hostname check
    "samsung": "phone", // Could be TV, needs service check
    "google": "iot", // Nest, Home devices
    "xiaomi": "phone",
    "oneplus": "phone",
    "huawei": "phone",
    
    // IoT
    "espressif": "iot", // ESP8266/ESP32
    "tuya": "iot",
    "tp-link": "iot", // Smart plugs
    "belkin": "iot", // WeMo
    "amazon": "media", // Echo, FireTV
    
    // Network
    "ubiquiti": "network",
    "cisco": "network",
    "netgear": "network",
    
    // Printers
    "hp": "printer",
    "canon": "printer",
    "epson": "printer",
    "brother": "printer",
    
    // Media
    "roku": "media",
    "sonos": "media",
    "lg electronics": "media",
    "vizio": "media",
    
    // Storage
    "synology": "storage",
    "qnap": "storage",
    "western digital": "storage",
    
    // Gaming
    "nintendo": "gaming",
    "sony interactive": "gaming",
    "microsoft": "gaming", // Xbox
}
```

## Recommendation

For production use in the network-metrics-exporter:

1. **Keep wimark/vendormap** for basic offline vendor lookup
2. **Add Fingerbank integration** for devices that send DHCP fingerprints
3. **Implement comprehensive vendor-to-type mapping** 
4. **Cache all classifications** by MAC address
5. **Add static overrides** for known problematic devices

This multi-layered approach will achieve 90%+ device classification accuracy while remaining resilient to API failures and rate limits.