# NixOS Self-Hosting Blog Post Series Outline

This is a series of blog posts documenting my NixOS self-hosting setup and the patterns I've developed for managing a heterogeneous fleet of devices.

## Core Architecture Posts

**1. "The Constellation Pattern: Composable Infrastructure with NixOS"**
- Your modular constellation system (common, services, media, backup, podman)
- How opt-in modules solve configuration duplication across hosts
- Real examples from your storage/cloud/embedded device fleet

**2. "Multi-Architecture Fleet Management with NixOS"**
- Managing x86 servers, ARM embedded devices, and Raspberry Pis
- Cross-compilation patterns and remote building strategies  
- Tailscale mesh networking as the backbone (*.bat-boa.ts.net)

**3. "Building a Self-Hosted Service Gateway with Dynamic Discovery"**  
- Your sophisticated media gateway system with automatic service registration
- Caddy + Tailscale Serve integration for external access
- Authentication bypass patterns and multi-host service federation

## Advanced Service Management

**4. "Supabase-as-a-Service: A Complete NixOS Module"**
- Your groundbreaking multi-instance Supabase module
- Declarative configuration generating Docker Compose
- Secret management and subdomain routing integration

**5. "Container Strategy: When to Use Podman vs Native NixOS Services"**
- Your hybrid approach: containers for AI/development, native for system services
- Hardware integration patterns (GPU passthrough to containers)
- Service isolation and networking considerations

**6. "Production-Grade Secret Management for Self-Hosters"**
- agenix patterns with per-host key restrictions
- Multi-target backup encryption strategies
- Zero-trust principles in home infrastructure

## Specialized Topics

**7. "NixOS on ARM: From Router Firmware to Production"**
- NanoPi R2S configuration with custom bootloader
- Cross-compilation workflows and OTA updates
- Network routing with nftables integration

**8. "Complete Media Pipeline: Acquisition to Consumption"**
- Your end-to-end stack: Prowlarr → Autobrr → Transmission → *arr suite
- FileFlows transcoding with Intel GPU acceleration
- Analytics and monitoring with Tautulli/Netdata

**9. "GitOps for Self-Hosters: Automated NixOS Deployments"**
- deploy-rs integration with Justfile automation
- Binary caching with Attic for faster builds
- Multi-host deployment strategies

**10. "Self-Hosted Monitoring: Beyond Basic Dashboards"**
- Netdata streaming architecture across multiple hosts
- SMART monitoring with email notifications
- Security monitoring with fail2ban integration

## Notes

Each post will showcase real configuration examples from the repository, demonstrating production-ready patterns that solve common self-hosting challenges. The focus is on practical, real-world implementations that other self-hosters can adapt and learn from.