# Router Installation Guide

This guide walks through installing NixOS with the router configuration on a new machine.

## Prerequisites

1. **Target Hardware**
   - x86_64 machine with NVMe storage (/dev/nvme0n1)
   - At least 4 network interfaces (1 WAN + 3 LAN ports)
   - Sufficient RAM for running services (4GB+ recommended)

2. **Pre-Installation Setup**
   - Ensure `hosts/router/interfaces.nix` exists (use the template as a starting point)
   - The file maps physical interface names to logical roles (wan, lan1, lan2, lan3)

3. **NixOS Installer**
   - Download NixOS installer ISO
   - Boot the target machine from the installer
   - Enable SSH: `systemctl start sshd`
   - Set root password: `passwd`
   - Note the IP address: `ip addr`

## Installation Steps

### 1. Install NixOS with Router Configuration

From your development machine:

```bash
# Install to the target host (replace IP_ADDRESS with actual IP)
just install router IP_ADDRESS
```

This command will:
- Connect to the installer via SSH
- Partition the disk using disko configuration
- Install NixOS with the router configuration
- Reboot the system automatically

> **Note**: The `just install` command is generic and can be used for any host in the flake.
> For example: `just install storage 192.168.1.50` or `just install cloud 10.0.0.100`

### 2. Post-Installation Setup

After the system reboots:

#### Generate Hardware Configuration
```bash
# Generate hardware-specific configuration
just hardware-config router router.local

# Review and commit the generated file
git add hosts/router/hardware-configuration.nix
git commit -m "router: Add hardware configuration"
```

#### Configure Network Interfaces

```bash
# List all physical network interfaces in Nix configuration format
just router-interfaces router.local
```

This outputs ready-to-use Nix configuration:
```nix
  router.interfaces = {
    wan = "enp1s0";    # WAN interface (MAC: 00:11:22:33:44:55, Link: UP)
    lan1 = "enp2s0";   # First LAN port (MAC: 00:11:22:33:44:56, Link: DOWN)
    lan2 = "enp3s0";   # Second LAN port (MAC: 00:11:22:33:44:57, Link: DOWN)
    lan3 = "enp4s0";   # Third LAN port (MAC: 00:11:22:33:44:58, Link: UP)
  };
```

To use this configuration:
1. Copy the output to `hosts/router/interfaces.nix` (replacing the example content)
2. Adjust the interface assignments based on your network topology
3. Commit and deploy:
   ```bash
   git add hosts/router/interfaces.nix
   git commit -m "router: Configure network interfaces"
   just deploy router
   ```

#### Set Up Tailscale
```bash
# On the router
tailscale up --advertise-routes=192.168.10.0/24 --advertise-exit-node
```

### 3. Deploy Updates

After initial installation, use deploy-rs for updates:

```bash
# Deploy configuration changes
just deploy router

# Deploy with boot changes (kernel, bootloader)
just boot router
```

## Customization

### Network Configuration
- Edit `hosts/router/network.nix` for firewall rules, DHCP settings
- Interface names are parameterized in `router.interfaces`
- Network prefix is configurable via `router.network`

To change the LAN network (default: 192.168.10.0/24), create a file with:
```nix
{
  router.network = {
    prefix = "10.0.50";  # Use 10.0.50.0/24 instead
    cidr = 24;
  };
}
```

### Services
- Edit `hosts/router/services.nix` for DNS, monitoring, UPnP settings
- Blocky DNS blocklists can be customized
- Grafana dashboards are auto-provisioned

### Local DNS Resolution
The router provides `.lan` domain names for local devices:
- `router.lan` - The router itself  
- `storage.lan` - Storage server (static IP)
- Add more devices by editing the customDNS mapping in `services.nix`

To add more local hostnames, edit `hosts/router/services.nix`:
```nix
customDNS = {
  mapping = {
    "router.lan" = routerIp;
    "storage.lan" = "${netConfig.prefix}.5";
    "desktop.lan" = "${netConfig.prefix}.10";  # Add your devices
    "printer.lan" = "${netConfig.prefix}.20";
  };
};
```

### Static DHCP Leases
Add entries in `hosts/router/network.nix`:
```nix
dhcpServerStaticLeases = [
  {
    dhcpServerStaticLeaseConfig = {
      Address = "192.168.10.10";
      MACAddress = "aa:bb:cc:dd:ee:ff";
    };
  }
];
```

## Troubleshooting

### Check Service Status
```bash
systemctl status systemd-networkd  # Network configuration
systemctl status nftables          # Firewall
systemctl status blocky            # DNS server
systemctl status miniupnpd         # UPnP/NAT-PMP
systemctl status prometheus        # Monitoring
```

### View Logs
```bash
journalctl -u systemd-networkd -f
journalctl -u blocky -f
journalctl -u miniupnpd -f
```

### Test Connectivity
```bash
# From a LAN client
ping 192.168.10.1              # Router LAN IP
ping router.lan                 # Router via .lan domain
nslookup example.com 192.168.10.1  # External DNS resolution
nslookup storage.lan 192.168.10.1  # Local DNS resolution
upnpc -l                        # UPnP discovery
```

### Access Monitoring
- Prometheus: http://192.168.10.1:9090
- Grafana: http://192.168.10.1:3000 (admin/admin)

## Network Topology

```
Internet
    |
[WAN: eth0] - DHCP from ISP
    |
[Router]
    |
[br-lan: <prefix>.1/24]  (default: 192.168.10.1/24)
    |
    +-- [LAN1: eth1] --|
    +-- [LAN2: eth2] --+-- Bridge
    +-- [LAN3: eth3] --|
    |
[LAN Clients: <prefix>.100-150]  (DHCP pool)
```