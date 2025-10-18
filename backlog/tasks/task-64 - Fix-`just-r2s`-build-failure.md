---
id: task-64
title: Fix `just r2s` build failure
status: To Do
assignee: []
created_date: '2025-10-18 20:13'
labels: []
dependencies: []
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
The `just r2s` command is failing with exit code 1. The build gets through the initial stages (building NixOS SD image, U-Boot, extracting image, writing bootloaders) but fails during the build/download phase. Need to investigate the root cause and fix the build.

Context:
- Modified hosts/r2s/sd-image.nix to add fake-hwclock module import
- Modified hosts/r2s/hardware-configuration.nix to enable fake-hwclock
- Build shows 54 derivations to build and 662 paths to fetch (1025.08 MiB download)
- The build progresses but fails at some point

Files involved:
- hosts/r2s/sd-image.nix
- hosts/r2s/hardware-configuration.nix
- hosts/r2s/configuration.nix
- justfile (r2s recipe)
<!-- SECTION:DESCRIPTION:END -->
