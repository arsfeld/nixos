# NixOS Router Blog Series Outline

## Series Overview: How to Build a NixOS Router

**Format**: Step-by-step how-to guides that build upon each other to create a fully functional NixOS router

**Target Audience**: Anyone who wants to build their own router with NixOS, from beginners to experienced users

**Goal**: By the end of this series, readers will have a working NixOS router with advanced features

**Repository**: https://github.com/arosenfeld/nixos-config

---

## How-To Guide 1: Getting Started - Hardware Selection and Basic NixOS Router Setup

**Goal**: Get a minimal NixOS router working with internet connectivity

### Steps Covered:
1. Choose your hardware
   - Budget option: Intel N5105 mini PC (~$150)
   - Requirements: 2+ NICs, x86_64 CPU, 4GB+ RAM
   - Where to buy (AliExpress, Amazon, etc.)
2. Install NixOS
   - Download ISO and create bootable USB
   - Basic installation steps
   - Initial network configuration
3. Create minimal router configuration
   - Basic NAT setup
   - DHCP server
   - Simple firewall rules
4. Test connectivity
   - Verify WAN connection
   - Test LAN clients
   - Basic troubleshooting

**Deliverable**: Working router that provides internet to your network

---

## How-To Guide 2: Add DNS with Ad Blocking

**Goal**: Set up Blocky for DNS resolution with ad blocking

### Steps Covered:
1. Install and configure Blocky
   - Basic Blocky configuration
   - Set up ad blocking lists
2. Configure local domain resolution
   - Add .lan domain for local devices
   - Create static DNS entries
3. Set up DNS forwarding
   - Configure upstream DNS servers
   - Add conditional forwarding for VPN
4. Test DNS functionality
   - Verify ad blocking works
   - Test local domain resolution

**Deliverable**: DNS server with ad blocking and local domains

---

## How-To Guide 3: Implement Advanced Firewall Rules

**Goal**: Create a comprehensive firewall with per-client tracking

### Steps Covered:
1. Set up nftables structure
   - Create proper chains
   - Implement stateful filtering
2. Add per-client traffic accounting
   - Track bandwidth per IP
   - Create accounting rules
3. Configure port forwarding
   - Static port forwards
   - Prepare for dynamic forwarding
4. Test firewall rules
   - Verify security
   - Check traffic accounting

**Deliverable**: Secure firewall with traffic monitoring capabilities

---

## How-To Guide 4: Enable UPnP for Gaming and P2P

**Goal**: Set up automatic port forwarding for devices that need it

### Steps Covered:
1. Install miniupnpd
   - Basic configuration
   - Security considerations
2. Integrate with firewall
   - Dynamic rule creation
   - Proper chain setup
3. Configure security limits
   - Port ranges
   - Lease times
   - Allowed clients
4. Test with gaming consoles
   - Verify NAT type improvement
   - Check P2P applications

**Deliverable**: Working UPnP that maintains security

---

## How-To Guide 5: Eliminate Bufferbloat with QoS

**Goal**: Implement CAKE QoS for smooth internet performance

### Steps Covered:
1. Measure your baseline
   - Test bufferbloat
   - Record latency under load
2. Configure CAKE
   - Set bandwidth limits
   - Enable ingress shaping
3. Apply DSCP markings
   - Prioritize important traffic
   - Configure ACK filtering
4. Verify improvements
   - Re-test bufferbloat
   - Measure real-world impact

**Deliverable**: Low-latency internet even under heavy load

---

## How-To Guide 6: Set Up Monitoring and Alerts

**Goal**: Know everything happening on your network

### Steps Covered:
1. Deploy Prometheus
   - Basic configuration
   - Add node exporter
2. Configure metrics collection
   - System metrics
   - Network statistics
   - Custom router metrics
3. Create Grafana dashboards
   - Import/create dashboards
   - Key metrics to track
4. Set up alerts
   - Critical conditions
   - Notification channels

**Deliverable**: Complete visibility into router performance

---

## How-To Guide 7: Add Remote Access with Tailscale

**Goal**: Access your network securely from anywhere

### Steps Covered:
1. Install Tailscale
   - Create account
   - Basic setup
2. Configure subnet routing
   - Advertise local network
   - Set up routes
3. Configure DNS integration
   - Remote DNS resolution
   - Split-horizon setup
4. Test remote access
   - Connect from outside
   - Verify local resource access

**Deliverable**: Secure remote access to home network

---

## How-To Guide 8: Write Tests for Your Configuration

**Goal**: Ensure your router configuration is reliable

### Steps Covered:
1. Introduction to NixOS tests
   - Basic test structure
   - Running tests locally
2. Write connectivity tests
   - Internet access
   - LAN connectivity
   - Service availability
3. Test your features
   - DNS resolution
   - Firewall rules
   - UPnP functionality
4. Integrate with deployment
   - Pre-deployment testing
   - Automated validation

**Deliverable**: Test suite that validates your router works correctly

---

## How-To Guide 9: Optimize Performance

**Goal**: Get maximum performance from your hardware

### Steps Covered:
1. Baseline performance testing
   - Measure throughput
   - Check CPU usage
2. Kernel tuning
   - Network stack optimization
   - IRQ affinity
3. Service optimization
   - Minimize resource usage
   - Disable unnecessary features
4. Verify improvements
   - Re-test performance
   - Monitor long-term stability

**Deliverable**: Router running at peak efficiency

---

## How-To Guide 10: Backup and Disaster Recovery

**Goal**: Ensure you can quickly recover from failures

### Steps Covered:
1. Set up configuration backups
   - Git repository setup
   - Secrets management
2. Create recovery procedures
   - Document recovery steps
   - Test restore process
3. Plan for hardware failure
   - Spare hardware options
   - Quick deployment strategy
4. Automate where possible
   - Backup automation
   - Deployment scripts

**Deliverable**: Robust backup and recovery plan

---

## Bonus How-To Guides

1. **Migrate from pfSense/OPNsense** - Step-by-step migration preserving your setup
2. **Add IPv6 Support** - Enable dual-stack networking
3. **Implement VLANs** - Segment your network properly
4. **Set Up IDS/IPS** - Add intrusion detection with Suricata
5. **Create a Test Lab** - Build a virtual test environment

## Series Structure

- Each guide builds on the previous ones
- Clear prerequisites stated at the beginning
- Exact commands and configuration provided
- Troubleshooting sections for common issues
- Links to relevant code in the repository
- "Checkpoint" configurations readers can use