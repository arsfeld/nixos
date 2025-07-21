# IPv6 Implementation Status for NixOS Router

## Current IPv6 Status

The router configuration currently has **minimal IPv6 support** with IPv6 explicitly disabled in most places.

### Current IPv6 Configuration

1. **IPv6 Forwarding**: Disabled
   - `network.nix:218`: `IPv6Forwarding = false`
   - `configuration.nix:26`: `"net.ipv6.conf.all.forwarding" = false`

2. **IPv6 on WAN**: Disabled
   - `network.nix:181`: `IPv6AcceptRA = false` (Router Advertisements disabled)

3. **Firewall**: IPv4-only
   - nftables rules only define `table ip` (IPv4) and `table inet` (dual-stack capable but only IPv4 rules defined)
   - No IPv6-specific rules or ICMPv6 handling
   - No ip6tables chains defined

4. **DNS**: IPv4-only
   - Blocky DNS configured with `connectIPVersion = "v4"`
   - No AAAA record support configured
   - No IPv6 upstream DNS servers

5. **DHCP**: IPv4-only
   - Only Kea DHCPv4 configured
   - No DHCPv6 or SLAAC configuration
   - No Router Advertisement daemon

## Missing Components for Full IPv6 Support

### 1. Basic IPv6 Connectivity
- [ ] Enable IPv6 on WAN interface with proper prefix delegation
- [ ] Enable IPv6 forwarding in kernel
- [ ] Configure IPv6 addresses on LAN bridge
- [ ] Enable Router Advertisements acceptance on WAN

### 2. IPv6 Address Assignment
- [ ] Configure Router Advertisement daemon (radvd or systemd-networkd RA)
- [ ] Set up SLAAC (Stateless Address Autoconfiguration)
- [ ] Optional: Configure DHCPv6 for stateful address assignment
- [ ] Configure prefix delegation from ISP

### 3. IPv6 Firewall Rules
- [ ] Add IPv6 firewall rules in nftables:
  - [ ] ICMPv6 rules (essential for IPv6 operation)
  - [ ] IPv6 forward chain rules
  - [ ] IPv6 NAT rules (if using NAT66, though not recommended)
  - [ ] IPv6-specific security rules

### 4. DNS for IPv6
- [ ] Enable AAAA record queries in Blocky
- [ ] Add IPv6 DNS servers (e.g., 2606:4700:4700::1111 for Cloudflare)
- [ ] Configure reverse DNS for IPv6 addresses
- [ ] Update custom DNS mappings to include IPv6 addresses

### 5. Services IPv6 Support
- [ ] Ensure all services bind to IPv6 addresses
- [ ] Update monitoring to track IPv6 traffic
- [ ] Configure UPnP/NAT-PMP alternatives for IPv6 (if needed)

## Recommended Implementation Steps

### Phase 1: Basic IPv6 Connectivity
1. Enable IPv6 on WAN with prefix delegation
2. Configure IPv6 on LAN bridge with delegated prefix
3. Set up basic IPv6 firewall rules
4. Enable IPv6 forwarding

### Phase 2: Address Assignment
1. Configure Router Advertisement daemon
2. Set up SLAAC for automatic address configuration
3. Optional: Add DHCPv6 for additional control

### Phase 3: Services Integration
1. Update DNS to support IPv6
2. Configure monitoring for IPv6
3. Test all services with IPv6

### Phase 4: Security Hardening
1. Implement comprehensive IPv6 firewall rules
2. Configure IPv6 privacy extensions
3. Set up IPv6 intrusion detection

## Example Configuration Snippets

### Enable IPv6 Forwarding
```nix
# In network.nix
networkConfig = {
  IPv4Forwarding = true;
  IPv6Forwarding = true;
  IPv6PrivacyExtensions = "kernel";
};

# In configuration.nix
boot.kernel.sysctl = {
  "net.ipv6.conf.all.forwarding" = 1;
  "net.ipv6.conf.default.forwarding" = 1;
};
```

### IPv6 Firewall Rules
```nix
# Add to nftables ruleset
table inet filter {
  chain input {
    # Essential ICMPv6 types
    ip6 nexthdr icmpv6 icmpv6 type { 
      destination-unreachable, 
      packet-too-big, 
      time-exceeded, 
      parameter-problem, 
      echo-request, 
      echo-reply,
      nd-router-solicit,
      nd-router-advert,
      nd-neighbor-solicit,
      nd-neighbor-advert
    } accept
  }
}
```

### Router Advertisement Configuration
```nix
# Using systemd-networkd
"40-br-lan" = {
  matchConfig.Name = "br-lan";
  networkConfig = {
    IPv6AcceptRA = false;
    IPv6SendRA = true;
    IPv6PrefixDelegation = "yes";
  };
  ipv6SendRAConfig = {
    RouterLifetimeSec = 1800;
    EmitDNS = true;
    DNS = "_link_local";
  };
  ipv6Prefixes = [{
    Prefix = "::/64";  # Will use delegated prefix
    PreferredLifetimeSec = 3600;
    ValidLifetimeSec = 7200;
  }];
};
```

### DNS IPv6 Support
```nix
services.blocky = {
  settings = {
    connectIPVersion = "dual";  # Enable both IPv4 and IPv6
    upstreams = {
      groups = {
        default = [
          "9.9.9.9"
          "2620:fe::fe"  # Quad9 IPv6
          "1.1.1.1"
          "2606:4700:4700::1111"  # Cloudflare IPv6
        ];
      };
    };
  };
};
```

## Testing IPv6 Implementation

1. **Verify IPv6 connectivity**: `ping6 2001:4860:4860::8888`
2. **Check routing**: `ip -6 route`
3. **Test DNS**: `dig AAAA google.com`
4. **Verify firewall**: `ip6tables -L -n -v`
5. **Check address assignment**: `ip -6 addr show`
6. **Test from clients**: Ensure clients get IPv6 addresses and can reach IPv6 sites

## Security Considerations

1. IPv6 addresses are globally routable by default (no NAT)
2. Proper firewall rules are essential
3. Consider privacy extensions for client addresses
4. Monitor for IPv6-specific attacks (RA flooding, etc.)
5. Ensure all services are properly secured for IPv6 access