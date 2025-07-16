+++
title = "Building a 2.5Gbps Home Router with NixOS"
date = 2025-07-16
description = "A technical journey building a NixOS-based router with 2.5Gbps support, advanced QoS, comprehensive monitoring, and declarative configuration. Includes lessons learned from previous attempts with pfSense and OPNsense."
[taxonomies]
tags = ["nixos", "networking", "homelab", "router"]
+++

![NixOS Router Setup](/images/nixos-router-hero.png)

**TL;DR**: Built a NixOS-based router on a $150 Intel N5105 mini PC that handles 2.5Gbps fiber with advanced QoS, monitoring, and declarative configuration. After experiences with pfSense and OPNsense, NixOS with comprehensive testing provides the control and reliability I was seeking. Check out the [full router configuration](https://github.com/arsfeld/nixos/tree/master/hosts/router).

## Motivation

Consumer routers work fine for most people. They're reliable, easy to set up, and just work. But if you're reading this, you're probably not "most people."

For me, the limitation wasn't about failures or frustration - it was about curiosity. I wanted to:

- See real traffic data, not just pretty graphs
- Add custom DNS rules for my homelab
- Experiment with different QoS algorithms
- Actually understand what my network was doing

Consumer routers are black boxes. Even the "advanced" settings are usually just basic toggles. Want to try a different packet scheduler? Add custom monitoring? Write your own firewall rules? Good luck with that.

## Evolution of My Router Setup

### First Attempt with NixOS

Three years ago, I discovered NixOS and was attracted to its declarative configuration approach. Version control for system configuration seemed ideal for a router.

The concept was appealing:
```nix
networking.firewall = {
  enable = true;
  # Just declare what I want!
};
```

However, I encountered challenges with UPnP implementation. Gaming consoles reported strict NAT types, and port forwarding proved difficult to configure properly. After multiple connectivity issues, I decided to switch to a more established solution.

### Experience with pfSense

pfSense provided a stable solution with its web UI, extensive package ecosystem, and strong community support. It served reliably for several years.

However, a configuration corruption incident after an update highlighted a critical limitation: without declarative configuration or version control, recovering the exact router state required manual reconstruction from memory.

### Transition to OPNsense

Following the pfSense incident, I migrated to OPNsense. It's well-engineered software with good stability and maintenance.

While functional, the GUI-based configuration lacked the version control and reproducibility benefits of declarative systems. The contrast with Infrastructure as Code principles was apparent.

### Return to NixOS with Better Tooling

In 2025, with improved tooling including AI coding assistants, I revisited NixOS for routing. The key difference was developing a comprehensive test suite.

The test coverage includes:
- Basic connectivity validation
- DNS resolution verification
- Firewall rule testing
- UPnP functionality checks

See the [complete test suite](https://github.com/arsfeld/nixos/blob/master/tests/router-test.nix) that validates the entire configuration.

This testing infrastructure enables confident deployment. Changes are validated before reaching production, ensuring network stability.

## Why NixOS for a Router?

With proper testing in place, all the NixOS benefits I originally wanted became reality:

**Declarative Configuration**: My entire router setup is in git. Every firewall rule, every service, every setting - tracked, reviewable, and reproducible.

```nix
# This is my actual DNS configuration
services.blocky = {
  enable = true;
  settings = {
    upstream.default = [
      "1.1.1.1"
      "8.8.8.8"
    ];
    blocking.blackLists = {
      ads = ["https://someonewhocares.org/hosts/zero/hosts"];
    };
    customDNS.mapping = {
      "router.lan" = "192.168.10.1";
      "nas.lan" = "192.168.10.10";
    };
  };
};
```

See the [full DNS configuration](https://github.com/arsfeld/nixos/tree/master/hosts/router/dns.nix) for complete setup including conditional forwarding for Tailscale.

**Atomic Updates**: Updates either work completely or roll back. No more half-applied configs that break networking.

**Reproducible Builds**: I can build the exact same router configuration on a test VM, verify it works, then deploy to production.

**Test-Driven Development**: Comprehensive testing enables reliable changes:

```nix
# Simplified example from my test suite
testScript = ''
  router.wait_for_unit("upnp")
  client.succeed("upnpc -a 192.168.10.2 8080 8080 TCP")
  router.succeed("nft list ruleset | grep 8080")
'';
```

## Considerations for Custom Solutions

Important considerations for custom router solutions:

**Full responsibility**: No vendor support available. Troubleshooting relies on system logs and personal expertise.

**Time constraints**: Network issues require immediate resolution, especially in households dependent on connectivity.

**Maintenance overhead**: Security updates, monitoring, and system health are self-managed.

The benefit is complete understanding and control of the network stack. Issues can be diagnosed and features added as needed.

## The Final Setup

Here's what I ended up with:

**Hardware**: A $150 Intel N5105 mini PC from [AliExpress](https://www.aliexpress.com/item/1005004822012472.html)
- 4-core Celeron with AES-NI (plenty for routing)
- 4x Intel I226-V 2.5GbE NICs
- 8GB RAM, 16GB NVMe
- Fanless, ~15W power draw
- Standard x86 architecture for broad compatibility

**Software Stack**:
- NixOS for the base system
- [nftables for firewall](https://github.com/arsfeld/nixos/tree/master/hosts/router/networking.nix)
- [Blocky for DNS with ad blocking](https://github.com/arsfeld/nixos/tree/master/hosts/router/dns.nix)
- [miniupnpd for UPnP/NAT-PMP](https://github.com/arsfeld/nixos/tree/master/hosts/router/upnp.nix)
- [CAKE for QoS and bufferbloat mitigation](https://github.com/arsfeld/nixos/tree/master/hosts/router/qos.nix)
- [Prometheus + Grafana for monitoring](https://github.com/arsfeld/nixos/tree/master/hosts/router/monitoring.nix)
- Tailscale for remote access

**Performance**: 
- 2.5Gbps symmetric with <1ms added latency
- Full IDS/IPS at line rate
- 50+ days uptime (only reboots for kernel updates)

## What's Next?

This is just the beginning. In the upcoming posts, I'll dive deep into:

1. **[Testing Your Router](#)** - How to build a [test suite](https://github.com/arsfeld/nixos/blob/master/tests/router-test.nix) that gives you deployment confidence
2. **[Network Architecture](#)** - [Bridging, VLANs, and firewall design](https://github.com/arsfeld/nixos/tree/master/hosts/router/networking.nix)
3. **[DNS Done Right](#)** - [Ad blocking, local domains, and split-horizon DNS](https://github.com/arsfeld/nixos/tree/master/hosts/router/dns.nix)
4. **[Advanced QoS](#)** - [Taming bufferbloat with CAKE](https://github.com/arsfeld/nixos/tree/master/hosts/router/qos.nix)
5. **[Comprehensive Monitoring](#)** - [Know *everything* about your network](https://github.com/arsfeld/nixos/tree/master/hosts/router/monitoring.nix)
6. **[VPN Integration](#)** - Tailscale subnet routing
7. **[Dynamic Port Forwarding](#)** - [UPnP that actually works](https://github.com/arsfeld/nixos/tree/master/hosts/router/upnp.nix)
8. **[Performance Tuning](#)** - Getting the most from your hardware
9. **[Lessons Learned](#)** - Mistakes made and future plans

The full configuration is available on [GitHub](https://github.com/arsfeld/nixos/tree/master/hosts/router). The [main configuration file](https://github.com/arsfeld/nixos/tree/master/hosts/router/configuration.nix) ties everything together. For details on how I manage NixOS across multiple hosts in my homelab, see my post on [Managing a Homelab with NixOS](https://blog.arsfeld.dev/posts/managing-homelab-with-nixos/).

## Conclusion

Building a custom router with NixOS requires significant technical investment. For my use case, the benefits of declarative configuration, comprehensive testing, and complete control justify the effort.

The combination of `nixos-rebuild switch` with passing tests provides confidence in network changes that GUI-based solutions cannot match.