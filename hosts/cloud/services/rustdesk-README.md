# RustDesk Server Configuration

This configuration sets up a complete RustDesk server using the built-in NixOS modules, with both the signal server (ID/registration) and relay server components running natively on the cloud host.

## Components

### RustDesk Signal Server (`hbbs`)
- **Ports**: 21115 (TCP), 21116 (TCP/UDP), 21118 (TCP), 21119 (TCP)
- **Function**: Handles ID registration, heartbeat, NAT type testing, and web client support
- **Service**: `systemctl status rustdesk-signal.service`

### RustDesk Relay Server (`hbbr`)  
- **Port**: 21117 (TCP)
- **Function**: Handles relay connections when direct connection fails
- **Service**: `systemctl status rustdesk-relay.service`

## Port Functions
- **21115**: NAT type test
- **21116**: ID registration and heartbeat (TCP/UDP)
- **21117**: Relay server
- **21118**: TCP hole punching and web client support
- **21119**: Web client support (can be disabled if not needed)

## Native NixOS Integration
- Uses the built-in `services.rustdesk-server` NixOS module
- Automatic firewall configuration (`openFirewall = true`)
- Native systemd service integration
- No Docker containers required
- No constellation gateway involvement (RustDesk uses its own protocol)

## Data Storage
- Data is stored in `/var/lib/rustdesk` (managed by systemd)
- Managed automatically by the NixOS module
- Uses dynamic user/group (`rustdesk`)

## Network Configuration
- Firewall rules automatically configured for all required ports
- Services run directly on their native ports
- No HTTP/HTTPS gateway needed (RustDesk uses its own protocol)

## Client Configuration
When configuring RustDesk clients, use:
- **ID Server**: `your-cloud-host.domain.com:21116`
- **Relay Server**: `your-cloud-host.domain.com:21117`
- **Key**: `_` (key verification disabled for easier setup)

Or if using Tailscale:
- **ID Server**: `cloud.bat-boa.ts.net:21116`
- **Relay Server**: `cloud.bat-boa.ts.net:21117`

## Security Features
- Key verification disabled (`-k "_"`) for simplified setup
- Can be re-enabled by removing the `-k "_"` from extraArgs and generating proper keys
- Firewall automatically configured to only allow required ports

## Maintenance
- Signal server logs: `journalctl -u rustdesk-signal.service`
- Relay server logs: `journalctl -u rustdesk-relay.service`
- Restart signal server: `systemctl restart rustdesk-signal.service`
- Restart relay server: `systemctl restart rustdesk-relay.service`
- Service status: `systemctl status rustdesk-signal.service rustdesk-relay.service`
- Check data directory: `ls -la /var/lib/rustdesk/`

## Advantages of Native NixOS Module
- Better integration with NixOS system management
- Automatic service dependencies and ordering
- No Docker overhead
- Standard systemd service management
- Automatic firewall configuration
- Better logging integration
- Proper systemd user/group isolation

## Enabling Key Authentication
To enable proper key authentication (recommended for production):

1. Remove `-k "_"` from both signal and relay `extraArgs`
2. Generate keys: `rustdesk-utils genkeypair`
3. Configure clients with the generated public key
4. Restart services

## Web Client Support
Ports 21118 and 21119 are for web client support. If you don't need web client access, these ports can be disabled by removing them from the firewall configuration.
