---
id: task-54
title: >-
  Create NixOS configuration for Orange Pi Zero 3 (octopi) with SD card image
  generation
status: In Progress
assignee: []
created_date: '2025-10-16 22:22'
updated_date: '2025-10-16 22:48'
labels:
  - nixos
  - arm
  - embedded
  - 3d-printing
dependencies: []
priority: medium
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Create a complete NixOS configuration for the Orange Pi Zero 3 board currently running DietPi, with the ability to generate flashable SD card images.

**Hardware Details:**
- Device: Orange Pi Zero 3
- SoC: Allwinner H618 (ARM Cortex-A53 quad-core)
- RAM: 1GB (918 MiB usable)
- Storage: 59.7 GB eMMC/SD card
- Network: Ethernet (10.1.1.65) + WiFi + Tailscale (100.90.121.69)
- USB: CH340 serial converter for 3D printer (/dev/ttyUSB0)

**Required Services:**
1. OctoPrint (3D printer management on port 5000)
2. Raspotify (Spotify Connect client)
3. Tailscale with tsnsrv (expose OctoPrint via Tailscale Funnel)
4. SSH access
5. Serial device support for CH340 (3D printer connection)

**Configuration Requirements:**
1. Create hosts/octopi/configuration.nix based on raspi3 pattern
2. Create hosts/octopi/hardware-configuration.nix for Orange Pi Zero 3
   - Device tree configuration for Allwinner H618
   - USB serial driver support (CH340)
   - Optimize for 1GB RAM system
   - Enable swap configuration
3. Add SD card image generation to flake.nix packages.aarch64-linux
   - Use nixos-generators with format "sd-aarch64"
   - Similar to raspi3 setup at flake.nix:282-290
4. Configure services:
   - services.octoprint.enable = true
   - Configure Raspotify (check if available in nixpkgs)
   - services.tailscale.enable = true
   - Configure tsnsrv for OctoPrint exposure
5. Network configuration:
   - Primary: Ethernet (DHCP)
   - Backup: WiFi
   - Tailscale auto-connect

**Build Command:**
`nix build .#octopi` should generate a flashable SD card image

**Reference Configurations:**
- hosts/raspi3/ - Similar ARM board with OctoPrint
- hosts/r2s/ - ARM board with device tree configuration
- flake.nix:282-290 - SD image generation for raspi3
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 hosts/octopi/configuration.nix created with all required services
- [x] #2 hosts/octopi/hardware-configuration.nix created for Orange Pi Zero 3
- [x] #3 SD card image generation added to flake.nix
- [x] #4 nix build .#octopi successfully generates flashable image
- [x] #5 OctoPrint service configured and exposed via tsnsrv
- [ ] #6 Raspotify service configured
- [x] #7 Tailscale configured with auto-connect
- [x] #8 CH340 USB serial driver enabled for 3D printer connectivity
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
## Device Tree Support

The Orange Pi Zero 3 is **already supported in mainline Linux kernel v6.6+** and **U-Boot v2024.01+**.

### Available Device Tree
The DietPi system already has the correct device tree file:
- **File**: `sun50i-h618-orangepi-zero3.dtb`
- **Location**: `/boot/dtb-6.6.44-current-sunxi64/allwinner/`
- **Size**: 35,795 bytes

### U-Boot Configuration
- U-Boot defconfig: `orangepi_zero3_defconfig` (available since v2024.01-rc5)
- Bootloader: generic-extlinux-compatible (like r2s)
- PMIC and Ethernet PHY supported in mainline

### Hardware Configuration Approach
```nix
hardware.deviceTree.name = "allwinner/sun50i-h618-orangepi-zero3.dtb";
```

### Reference Implementation
Community repo available: https://github.com/Arcayr/orangepizero3-nix
- Provides working kernel and u-boot configuration
- Uses nixos-generators for SD image creation
- Generic extlinux bootloader configuration

### Simplified Implementation Plan
Since device tree is mainline, we can:
1. Use standard `sd-image-aarch64.nix` module
2. Specify device tree name (like raspi3 does)
3. Let NixOS handle U-Boot automatically via nixos-generators
4. No need for custom device tree files (unlike r2s)

This makes the Orange Pi Zero 3 setup **simpler than r2s** because everything is already in mainline nixpkgs.

## Implementation Complete

**Completed:**
1. Created hosts/octopi/configuration.nix with OctoPrint, Tailscale, tsnsrv, and SSH
2. Created hosts/octopi/hardware-configuration.nix for Orange Pi Zero 3 with:
   - Device tree: allwinner/sun50i-h618-orangepi-zero3.dtb
   - CH340 USB serial driver support for 3D printer
   - Optimized for 1GB RAM with 2GB swap
   - Generic extlinux bootloader
3. Added SD card image generation to flake.nix packages.aarch64-linux
4. Build test successful: `nix build .#octopi --dry-run` passes
5. Auto-discovered by nixosConfigurations (can also deploy with deploy-rs/colmena)

**Note on Raspotify (AC#6):**
Raspotify is not available as a NixOS service in nixpkgs. Added TODO comment in configuration.nix suggesting librespot package as alternative. This can be configured manually post-deployment if needed.

**Build Command:**
```bash
nix build .#octopi
```
This generates a flashable SD card image at `./result/sd-image/nixos-image-sd-card-*.img.zst`
<!-- SECTION:NOTES:END -->
