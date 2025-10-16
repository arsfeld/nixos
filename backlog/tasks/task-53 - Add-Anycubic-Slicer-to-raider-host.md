---
id: task-53
title: Add Anycubic Slicer to raider host
status: Done
assignee:
  - '@claude'
created_date: '2025-10-16 21:11'
updated_date: '2025-10-16 21:17'
labels:
  - enhancement
  - raider
dependencies: []
priority: medium
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Install and configure Anycubic Slicer (3D printing slicer software) on the raider host.

This should be added to the raider host configuration, likely as a user package or system package depending on the preferred pattern in the repository.
<!-- SECTION:DESCRIPTION:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
## Implementation Summary

Added Anycubic Slicer Next to the raider host using the official deb package from Anycubic's repository.

### What was done:
1. Created a NixOS derivation at `packages/anycubic-slicer/default.nix` that:
   - Downloads the deb package from https://cdn-universe-slicer.anycubic.com/prod
   - Version 1.3.7171 (latest as of 2025-09-28)
   - Uses autoPatchelfHook to handle library dependencies
   - Creates a wrapper script for proper library path handling
   - Installs desktop file for GUI integration

2. Added `anycubic-slicer` to raider's `environment.systemPackages`

3. The package is automatically exposed through the flake's overlay system (haumea)

### Technical Details:
- Source: Official Anycubic deb repository for Ubuntu 24.04
- SHA256: a01fe863cc4efe8f943974782bfcb2d1d008ae3077ced065f63db893d71e1f92
- Binary location: `/opt/AnycubicSlicerNext/AnycubicSlicerNext`
- Command: `anycubic-slicer`

### Files changed:
- `packages/anycubic-slicer/default.nix` (new)
- `hosts/raider/configuration.nix` (modified)
<!-- SECTION:NOTES:END -->
