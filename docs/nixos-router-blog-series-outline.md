# NixOS Router Blog Series Outline

## Series Overview

**Tone**: Technically enthusiastic and pragmatic - focus on the engineering journey, technical challenges, and solutions. Share experiences and learnings without unnecessary drama. Be clear, direct, and informative while maintaining accessibility.

**Target Audience**: Homelab enthusiasts, NixOS users, and anyone interested in building their own router with advanced features.

**Repository**: https://github.com/arosenfeld/nixos-config (adjust to actual repo URL)

---

## Post 1: Building a 2.5Gbps Home Router with NixOS - Why I Ditched Consumer Routers

**TL;DR**: Fed up with consumer router limitations, I built a powerful NixOS-based router that handles 2.5Gbps fiber, advanced QoS, comprehensive monitoring, and more - all with declarative configuration.

### Outline:
- The breaking point with consumer routers
  - Limited customization
  - Poor monitoring capabilities
  - Vendor lock-in and EOL concerns
- Evolution of my router setup
  - First attempt with NixOS
    - Attracted to declarative configuration
    - Struggled with UPnP implementation
    - Moved to pfSense for stability
  - Experience with pfSense
    - Solid performance for several years
    - Configuration loss incident highlighted backup limitations
    - No version control for router state
  - Transition to OPNsense
    - Reliable alternative after pfSense
    - Still missed declarative approach
  - Return to NixOS with better tooling
    - AI tools helped develop comprehensive test suite
    - Testing enables confident deployments
    - Finally achieved original vision
- Why NixOS for a router? (Take 2)
  - Declarative configuration = version control for your network
  - Atomic updates and rollbacks
  - Reproducible builds
  - Test-driven development for network infrastructure
- Considerations for custom solutions
  - Full responsibility for maintenance
  - No vendor support
  - Time investment required
  - Need to manage all aspects
  - Benefit: Complete control and understanding
- Overview of the final setup
  - Hardware choices
    - Cheap Intel N5105 mini PC from AliExpress (~$150)
    - 4x Intel I226-V 2.5GbE NICs
    - 8GB RAM, 16GB NVMe
    - Fanless, low power (~10-15W)
    - Link: https://www.aliexpress.com/item/1005004822012472.html
    - Overkill for most home networks, but standard x86 = easy setup
  - Key features achieved
  - Performance numbers
- Series roadmap and what's coming

**Links to**: Repository, next posts in series

---

## Post 2: Testing Your Router - NixOS Tests and Validation

**TL;DR**: Writing comprehensive NixOS tests to validate your router configuration and catch issues before deployment.

### Outline:
- Why testing matters for network infrastructure
  - First NixOS router attempt failed without proper testing
  - Network reliability is critical for modern homes
  - Tests enable confident iteration
- Introduction to NixOS testing framework
  - How NixOS tests work
  - Running tests locally before deployment
- Test scenarios covered
  - Basic connectivity tests
  - Firewall rule validation  
  - DNS resolution tests
  - Traffic shaping verification
  - Service availability checks
  - UPnP functionality validation
- Writing custom test cases
  - Testing specific network configurations
  - Simulating client devices
- Leveraging AI for test development
  - Using AI tools for test generation
  - Examples of comprehensive test scenarios
- CI/CD integration possibilities
- Test-driven router development

---

## Post 3: Network Architecture - Bridging, VLANs, and Firewall Design

**TL;DR**: How to set up a proper network architecture with NixOS - from bridging multiple LAN ports to implementing a stateful firewall with per-client traffic accounting.

### Outline:
- Physical network layout
  - WAN + 3 LAN ports configuration
  - Creating a LAN bridge with systemd-networkd
- Firewall architecture with nftables
  - Stateful packet filtering basics
  - NAT/masquerading setup
  - Per-client traffic accounting implementation
  - Dynamic UPnP port forwarding chains
- DHCP server configuration
  - Static reservations for known devices
  - Integration with DNS
- Code walkthrough of `networking.nix`

---

## Post 4: DNS Done Right - Ad Blocking, Local Domains, and Split Horizon with Blocky

**TL;DR**: Setting up Blocky as a privacy-focused DNS server with ad blocking, custom local domains, and conditional forwarding for VPN networks.

### Outline:
- Why Blocky over Pi-hole or AdGuard Home
  - Single binary, cloud-native design
  - YAML configuration fits well with Nix
- Configuration deep dive
  - Ad blocking with curated lists
  - Custom DNS mappings for `.lan` domain
  - Conditional forwarding for Tailscale (`.ts.net`)
  - Prometheus metrics integration
- Performance tuning
  - Caching strategies
  - Parallel upstream queries
- Real-world results and blocked query statistics

---

## Post 5: Advanced QoS with CAKE - Taming Bufferbloat on Multi-Gigabit Fiber

**TL;DR**: Implementing CAKE (Common Applications Kept Enhanced) QoS to eliminate bufferbloat and ensure smooth performance even at 2.5Gbps speeds.

### Outline:
- What is bufferbloat and why it matters
  - The problem with large buffers
  - Impact on video calls and gaming
- CAKE algorithm explained
  - How it differs from traditional QoS
  - Per-flow isolation benefits
- Implementation details
  - Setting up ingress shaping with IFB
  - Bandwidth limiting (90% of line rate)
  - DSCP marking for traffic classification
  - ACK filtering for asymmetric connections
- Performance testing and results
  - Before/after latency measurements
  - Impact on real-world usage

---

## Post 6: Comprehensive Monitoring - Prometheus, Grafana, and Custom Metrics

**TL;DR**: Building a complete monitoring stack that tracks everything from per-client bandwidth usage to DNS query patterns and internet speed tests.

### Outline:
- The monitoring stack
  - Prometheus for metrics collection
  - Grafana for visualization
  - Node exporter for system metrics
- Custom metrics collection
  - Per-client traffic tracking implementation
  - UPnP activity monitoring
  - QoS statistics extraction
  - Automated speed tests
- Grafana dashboards
  - System overview dashboard
  - Network traffic dashboard
  - DNS analytics dashboard
- Setting up alerts
  - Alertmanager configuration
  - Multi-channel notifications (email, Discord, ntfy.sh)

---

## Post 7: VPN Integration - Tailscale Subnet Routing and Remote Access

**TL;DR**: Using Tailscale to securely access your home network from anywhere and share local resources with remote devices.

### Outline:
- Why Tailscale?
  - Zero-config WireGuard
  - NAT traversal that actually works
- Subnet router configuration
  - Advertising local networks
  - Access control policies
- Integration with local services
  - DNS configuration for remote clients
  - Accessing local services securely
- Performance considerations
  - MTU optimization
  - Routing efficiency

---

## Post 8: Dynamic Port Forwarding with UPnP/NAT-PMP

**TL;DR**: Implementing automatic port forwarding for gaming consoles and P2P applications while maintaining security.

### Outline:
- UPnP vs NAT-PMP explained
- miniupnpd configuration
  - Security considerations
  - Port range restrictions
  - Lease time management
- Firewall integration
  - Dynamic nftables rules
  - Monitoring active mappings
- Real-world usage
  - Gaming console NAT types
  - P2P application compatibility

---

## Post 9: Performance Tuning and Hardware Considerations

**TL;DR**: Optimizing NixOS for router workloads and choosing the right hardware for your needs.

### Outline:
- Hardware selection: Intel N5105 mini PC
  - Key specifications
    - $150 4-core Celeron with AES-NI
    - 4x Intel I226-V 2.5GbE NICs
    - Fanless design for silent operation
    - 10W TDP suitable for continuous use
  - Actual specs from production:
    - Intel Celeron N5105 @ 2.00GHz (turbo to 2.9GHz)
    - 8GB RAM (plenty for routing + services)
    - 16GB Intel Optane NVMe (overkill but fast)
    - Real power usage: ~10-15W under load
- Hardware selection criteria
  - CPU requirements for packet processing
  - NIC selection (Intel vs Realtek)
  - Storage considerations (F2FS on NVMe)
- NixOS optimizations
  - Minimal package set
  - Kernel tuning
  - Service optimization
- Performance headroom benefits
  - Capable of 10Gbps routing
  - Room for additional services
  - x86 architecture compatibility
- Power consumption
  - Measuring actual usage
  - Power-saving features
- Thermal management

---

## Post 10: Lessons Learned and Future Improvements

**TL;DR**: Reflecting on the journey, sharing mistakes made, and discussing planned improvements like BGP peering and IPv6 support.

### Outline:
- What went well
  - Stability and reliability
  - Performance achievements
  - Maintenance experience
- Challenges faced
  - Initial learning curve
  - Hardware quirks
  - Service integration issues
- Future roadmap
  - IPv6 implementation
  - BGP peering possibilities
  - Additional monitoring metrics
  - Container-based service isolation
- Community and contributions

---

## Bonus Posts (Potential)

1. **Migrating from pfSense/OPNsense to NixOS** - A practical migration guide
2. **Building a Travel Router with Similar Config** - Adapting for portable use
3. **Cost Analysis** - TCO compared to commercial solutions
4. **Troubleshooting Common Issues** - Debug guide for network problems

## Cross-Post Elements

- Each post starts with TL;DR
- Links to repository and related posts
- Code snippets with explanations
- Real-world performance metrics
- Diagrams where helpful
- "Try it yourself" sections with minimal configs