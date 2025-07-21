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

## How-To Guide 2: Write Tests for Your Configuration

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
   - Basic NAT and DHCP
   - Firewall rules
   - Network isolation
4. Integrate with deployment
   - Pre-deployment testing
   - Automated validation

**Deliverable**: Test suite that validates your router works correctly

---

## How-To Guide 3: Monitor Per-Client Network Usage with Custom Metrics

**Goal**: Track exactly how much bandwidth each device uses in real-time

### Steps Covered:
1. Set up basic monitoring stack
   - Quick Prometheus setup
   - Basic Grafana configuration
   - Standard node exporter for system metrics
2. Deep dive: network-metrics-exporter
   - What makes this exporter special
   - How it tracks per-client bandwidth
   - Understanding the metrics it provides
3. Configure the exporter
   - Enable nftables integration
   - Set up persistent client names
   - Configure update intervals
4. Build powerful dashboards
   - Real-time bandwidth graphs per client
   - Connection tracking visualization
   - Device online/offline status
   - Top bandwidth consumers

**Deliverable**: Real-time visibility into which devices use your bandwidth

---

## How-To Guide 4: Enable Automatic Port Forwarding with Custom NAT-PMP Server

**Goal**: Build a modern, reliable NAT-PMP server for gaming and P2P applications

### Steps Covered:
1. Why NAT-PMP over UPnP
   - Simpler protocol, better security
   - Issues with miniupnpd on modern systems
   - Benefits of a custom implementation
2. Deep dive: natpmp-server
   - Architecture and design decisions
   - How it integrates with nftables
   - Persistent state management
   - Built-in Prometheus metrics
3. Configure and deploy
   - Set up the NixOS module
   - Configure port ranges and limits
   - Enable persistent mappings
   - Monitor with metrics
4. Test with real applications
   - Gaming consoles (Nintendo Switch, etc.)
   - BitTorrent clients
   - Other NAT-PMP compatible software
   - Using the Python test client

**Deliverable**: Modern NAT-PMP server that just works™

---

## How-To Guide 5: Add DNS with Ad Blocking

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

## How-To Guide 6: Implement Advanced Firewall Rules

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

## How-To Guide 7: Eliminate Bufferbloat with QoS

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

## How-To Guide 8: Add Remote Access with Tailscale

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
6. **Declarative Grafana Dashboards** - Make your entire monitoring stack reproducible

### Declarative Grafana Dashboards Guide

**Goal**: Create fully declarative, version-controlled Grafana dashboards that deploy automatically

#### Steps Covered:
1. Why declarative dashboards matter
   - Version control for your visualizations
   - Reproducible monitoring across deployments
   - No manual dashboard creation needed
   - Collaborative dashboard development

2. Structure your dashboards
   - Modular panel organization
   - Reusable panel templates
   - Dynamic variable injection
   - Multi-dashboard management

3. NixOS Grafana provisioning
   - Dashboard provisioning configuration
   - Datasource auto-configuration
   - Folder organization
   - Permission management

4. Advanced techniques
   - Template variables from Nix config
   - Dynamic panel generation
   - Cross-dashboard linking
   - Alert rule provisioning

**Deliverable**: Monitoring stack where every dashboard is code

## Series Structure

- Each guide builds on the previous ones
- Clear prerequisites stated at the beginning
- Exact commands and configuration provided
- Troubleshooting sections for common issues
- Links to relevant code in the repository
- "Checkpoint" configurations readers can use