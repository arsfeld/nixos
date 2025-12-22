---
id: task-159.1
title: Create constellation.home-assistant NixOS module
status: Done
assignee: []
created_date: '2025-12-15 03:09'
updated_date: '2025-12-15 03:43'
labels:
  - nixos
  - storage
dependencies: []
parent_task_id: task-159
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Create a new constellation module for Home Assistant at `modules/constellation/home-assistant.nix`.

**Module structure:**
```nix
{ config, lib, pkgs, ... }:
{
  options.constellation.home-assistant = {
    enable = lib.mkEnableOption "Home Assistant";
  };

  config = lib.mkIf config.constellation.home-assistant.enable {
    services.home-assistant = {
      enable = true;
      configWritable = true;  # Allow HACS and UI modifications
      
      extraComponents = [
        "default_config"
        "met"
        "esphome"
      ];
      
      customComponents = with pkgs.home-assistant-custom-components; [
        tuya-local
        alarmo
      ];
      
      config = {
        homeassistant = {
          name = "Home";
          time_zone = "America/Toronto";
        };
        http = {
          server_host = "0.0.0.0";
          server_port = 8123;
          use_x_forwarded_for = true;
          trusted_proxies = [ "127.0.0.1" "100.64.0.0/10" ];
        };
        # Allow UI-managed files
        "automation ui" = "!include automations.yaml";
        "scene ui" = "!include scenes.yaml";
        "script ui" = "!include scripts.yaml";
      };
    };
  };
}
```

**Files to create:**
- `modules/constellation/home-assistant.nix`

**Files to modify:**
- `modules/constellation/default.nix` - Import the new module
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Module file created at modules/constellation/home-assistant.nix
- [ ] #2 Module imported in modules/constellation/default.nix
- [x] #3 constellation.home-assistant.enable option available
- [x] #4 services.home-assistant configured with basic settings
- [x] #5 tuya_local and alarmo custom components included
- [x] #6 configWritable enabled for HACS support
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Configuration already in place - hass in bypassAuth (line 115) and D-Bus mount present (line 98)

## Implementation Complete

**Module Created:** `/home/arosenfeld/Code/nixos/modules/constellation/home-assistant.nix`

**Key Implementation Details:**

1. **Module Structure:** Follows the standard constellation module pattern with:
   - Options section defining `constellation.home-assistant.enable`
   - Config section with `lib.mkIf` guard
   - Comprehensive documentation header

2. **Home Assistant Configuration:**
   - `configWritable = true` - Allows HACS installations and UI modifications to persist
   - `extraComponents` - Includes default_config, met (weather), and esphome
   - `customComponents` - Includes tuya-local and alarmo from nixpkgs
   - Port 8123 with reverse proxy support (trusted_proxies for localhost and Tailscale)
   - UI-managed automation, scene, and script files via !include directives

3. **Module Auto-Loading:**
   - **IMPORTANT:** There is NO `modules/constellation/default.nix` file
   - Modules are automatically loaded via haumea in `flake.nix` (lines 191-197)
   - All `.nix` files in `modules/` and subdirectories are auto-discovered
   - No manual import required - the module is immediately available

4. **Verification:**
   - Module syntax validated with `nix-instantiate --parse`
   - Code formatted with `alejandra`
   - Ready to be enabled with `constellation.home-assistant.enable = true;`

**Next Steps (for task-159.2):**
- Enable the module on storage host
- Configure secrets for integrations
- Add service to constellation.services for gateway access

Module created and auto-loaded via haumea (no default.nix import needed). Criterion #2 was based on incorrect assumption - flake uses haumea to auto-load all .nix files from modules/
<!-- SECTION:NOTES:END -->
