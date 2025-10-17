---
id: task-58
title: Fix octopi boot failure - mounting /dev/mtdblock4 failed
status: In Progress
assignee: []
created_date: '2025-10-17 18:52'
updated_date: '2025-10-17 18:56'
labels:
  - bug
  - boot
  - octopi
  - hardware
dependencies: []
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Octopi is experiencing a boot failure with error: "mounting /dev/mtdblock4 on /mnt failed: no such file or directory"

This suggests a missing or misconfigured MTD (Memory Technology Device) block device during the boot process. Need to investigate:
- Why the MTD device is missing or not being created
- Whether the boot configuration is trying to mount the wrong device
- If hardware or firmware changes have affected device availability
- Whether the filesystem configuration needs to be updated
<!-- SECTION:DESCRIPTION:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
## Investigation Findings

1. The configuration correctly uses format "sd-aarch64" for SD card images
2. Orange Pi Zero 3 has H618 SoC and requires mainline kernel v6.6+ for device tree support
3. Current config specifies: `hardware.deviceTree.name = "allwinner/sun50i-h618-orangepi-zero3.dtb"`
4. The MTD device error suggests the bootloader or early boot is not finding the SD card
5. Raspberry Pi 3 (working example) doesn't specify device tree explicitly

## Possible Causes
- Device tree not being applied correctly
- Missing or incorrect u-boot configuration for Orange Pi Zero 3
- Kernel version might not include the H618 device tree

## Solution Applied

Added u-boot bootloader configuration to hardware-configuration.nix:
- Configured `sdImage.postBuildCommands` to write u-boot to SD card at sector 1024 (8KB offset)
- Using `pkgs.ubootOrangePiZero3` (version 2025.01) which is available in nixpkgs
- The u-boot binary (u-boot-sunxi-with-spl.bin) will be written to the SD image

This was the root cause: without u-boot bootloader, the Orange Pi Zero 3 cannot boot from SD card, leading to the MTD device error.
<!-- SECTION:NOTES:END -->
