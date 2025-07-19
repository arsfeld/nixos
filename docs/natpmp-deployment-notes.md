# NAT-PMP Server Deployment Notes

## Overview
The NAT-PMP server is now fully functional on the NixOS router with all critical issues resolved.

## Fixed Issues

### 1. Deadlock Issue (FIXED)
**Problem**: The server had a critical deadlock where `SaveState()` tried to acquire a read lock while `AddMapping()` already held a write lock.

**Solution**: Created an internal `saveStateInternal()` function that doesn't acquire locks, to be used when already holding a lock.

### 2. Duplicate Mappings (FIXED)
**Problem**: The server was creating duplicate entries every time a client requested the same port mapping.

**Solution**: Added `FindExistingMapping()` to check for existing mappings and update them instead of creating duplicates.

### 3. Firewall Blocking DNAT Traffic (FIXED)
**Problem**: The router's forward chain had a drop policy that blocked incoming DNAT traffic.

**Solution**: Added `ct status dnat accept` rule to the forward chain to accept all DNAT traffic.

### 4. Rules Lost on nftables Reload (FIXED)
**Problem**: NAT-PMP dynamically adds nftables rules that are lost when nftables is reloaded.

**Solution**: Created `/etc/nftables-reload-wrapper` script that:
- Reloads nftables
- Automatically restarts NAT-PMP server to recreate rules

## Configuration Summary

### Router Firewall (network.nix)
```nix
chain forward {
  type filter hook forward priority 0; policy drop;
  # ... other rules ...
  ct state established,related accept
  
  # Accept traffic that has been DNAT'd (for NAT-PMP and miniupnpd)
  ct status dnat accept
}
```

### NAT-PMP Service (natpmp.nix)
- External interface: WAN interface (enp2s0)
- Listen interface: br-lan
- Port range: 1024-65535
- Max mappings per client: 50
- Custom nftables chains: NATPMP_DNAT and NATPMP_FORWARD

## Usage

### Creating Port Mappings
```bash
# From a LAN client
python3 test-natpmp.py router.ip map <internal_port> <external_port> <tcp|udp> <lifetime>

# Example: Map TCP port 8080
python3 test-natpmp.py 10.1.1.1 map 8080 8080 tcp 3600
```

### Reloading nftables
Use the wrapper script to ensure NAT-PMP rules are preserved:
```bash
/etc/nftables-reload-wrapper
```

### Monitoring
```bash
# Check service status
systemctl status natpmp-server

# View logs
journalctl -u natpmp-server -f

# Check active mappings
nft list chain ip nat NATPMP_DNAT

# View metrics
curl http://router:9333/metrics | grep natpmp
```

## Testing Results
- ✅ Port mappings work correctly
- ✅ External access to mapped ports confirmed
- ✅ No duplicate mappings created
- ✅ Rules persist across nftables reloads
- ✅ No deadlocks or hangs