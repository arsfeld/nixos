---
title: "feat: Add Steam Deck-style performance OSD"
type: feat
status: active
date: 2026-04-02
origin: docs/brainstorms/2026-04-02-performance-osd-brainstorm.md
---

# feat: Add Steam Deck-style performance OSD

## Overview

Add a MangoHud-based performance overlay to the gaming module for raider and g14. The overlay provides 4 cycling levels (OFF, FPS, Detail, Full) like the Steam Deck, loaded per-game only (not session-wide), toggled via keyboard and gamepad.

This replaces the currently disabled MangoHud config in `home/home.nix:565-793` (which used a fragile 130-app blacklist for session-wide filtering).

## Problem Statement / Motivation

Gaming on raider and g14 lacks a quick way to check performance metrics (FPS, GPU/CPU load, temps, power) during gameplay. The previous MangoHud setup was disabled because the session-wide + blacklist approach was brittle. A per-game approach eliminates the blacklist entirely.

## Proposed Solution

**MangoHud per-game loader** with 4-level preset cycling:

| Level | Display | MangoHud Config |
|-------|---------|-----------------|
| 0 (default) | Hidden | `no_display` preset |
| 1 | FPS counter only | `fps` only |
| 2 | Detail | FPS + CPU/GPU usage %, temps, power |
| 3 | Full | Frametime graph, per-core CPU, VRAM, RAM, battery (g14) |

**Activation:** Per-game via `mangohud %command%` in Steam launch options, Lutris runner settings, or `mangohud ./game` wrapper. Never session-wide.

**Toggle:** `Shift_R+F12` cycles presets. Gamepad combo via antimicrox maps to same keybind (non-Steam games only — see limitations).

## Technical Considerations

### MangoHud Preset Cycling Mechanism

MangoHud's `toggle_hud` is binary (on/off). For 4-level cycling, use `toggle_preset` with numbered preset blocks. The "hidden" state uses `no_display` within preset 0.

**Two keybinds needed:**
- `toggle_preset = "Shift_R+F12"` — cycles through levels 0-3
- `toggle_hud = "Shift_R+F11"` — emergency full hide/show (backup)

**Risk:** `no_display` in preset 0 needs verification on current nixpkgs MangoHud version. If unreliable, fall back to: preset 1-3 for visible levels + `toggle_hud` for hide/show (3 visible levels + off, using 2 keybinds).

### Per-Host GPU Targeting

MangoHud defaults to reading the display GPU. This is wrong on g14 (games render on NVIDIA dGPU, display is on AMD iGPU).

| Host | Display GPU | Gaming GPU | MangoHud target |
|------|------------|------------|-----------------|
| raider | AMD RX 6650 XT | AMD RX 6650 XT (same) | Default (auto) |
| g14 | AMD Renoir iGPU | NVIDIA GTX 1660 Ti | Needs explicit PCI address |

Use `osConfig.networking.hostName` in home-manager to conditionally set `pci_dev` for g14. The NVIDIA PCI address is in `hosts/g14/hardware-configuration.nix`.

### antimicrox vs Steam Input

Steam Input grabs exclusive gamepad access for games using it (most Steam games). antimicrox cannot see the controller when Steam Input is active. **Gamepad toggle only works for non-Steam games and Steam games with Steam Input disabled.** This is a known limitation — document it, don't try to solve it.

### Wrapper Ordering on g14

On g14, games launched with NVIDIA PRIME need correct wrapper order:
- Steam: `nvidia-offload mangohud %command%`
- Manual: `nvidia-offload mangohud ./game`

The existing `nvidia-offload` script (`home/home.nix:10-16`) sets PRIME env vars.

## Acceptance Criteria

- [x] `constellation.gaming.performanceOsd` option added to gaming module (default: `true`)
- [x] MangoHud config in `home/mangohud.nix` with 4 preset levels, conditional on `osConfig`
- [x] Old MangoHud config + blacklist removed from `home/home.nix:565-793`
- [x] Correct GPU targeted on both raider (auto) and g14 (explicit PCI address)
- [x] Overlay starts hidden, `Shift_R+F12` cycles through levels
- [x] Builds successfully on both raider and g14: `nix build .#nixosConfigurations.raider.config.system.build.toplevel` and `nix build .#nixosConfigurations.g14.config.system.build.toplevel`

## Implementation Phases

### Phase 1: Gaming module option

Add `performanceOsd` bool option to `modules/constellation/gaming.nix` following the existing `kernelOptimizations` pattern (lines 11-15).

**File:** `modules/constellation/gaming.nix`

```nix
# Add after cpuVendor option (line 27)
performanceOsd = lib.mkOption {
  type = lib.types.bool;
  default = true;
  description = "Enable MangoHud performance overlay with Steam Deck-style preset cycling";
};
```

### Phase 2: MangoHud home-manager config

Create `home/mangohud.nix` following the `home/niri.nix` pattern. Import it from `home/home.nix`.

**File:** `home/mangohud.nix`

```nix
{
  config,
  pkgs,
  lib,
  osConfig ? null,
  ...
}: let
  gamingEnabled = osConfig != null
    && (osConfig.constellation.gaming.enable or false)
    && (osConfig.constellation.gaming.performanceOsd or true);
  hostname = if osConfig != null then osConfig.networking.hostName else "";
  isG14 = hostname == "g14";
in {
  config = lib.mkIf gamingEnabled {
    programs.mangohud = {
      enable = true;
      enableSessionWide = false;
      settings = {
        # Use preset cycling instead of single config
        toggle_preset = "Shift_R+F12";
        toggle_hud = "Shift_R+F11";

        # Position and style
        position = "top-left";
        font_size = 18;
        background_alpha = "0.3";
        background_color = "020202";
        round_corners = 5;

        # Default state: hidden (preset 0 overrides to no_display)
        no_display = true;

        # GPU targeting for g14 NVIDIA PRIME
        # pci_dev conditionally set below
      }
      // lib.optionalAttrs isG14 {
        pci_dev = "0000:01:00.0";  # NVIDIA GTX 1660 Ti
        battery = true;
      };
    };

    # MangoHud preset configs (XDG config files)
    # Preset 0: Hidden
    # Preset 1: FPS only
    # Preset 2: Detail
    # Preset 3: Full
    xdg.configFile."MangoHud/presets.conf".text = ''
      # ... preset definitions
    '';
  };
}
```

**Note:** MangoHud preset file format needs verification — presets may be defined in the main config via `[preset N]` sections or as separate files. Verify against current MangoHud docs during implementation.

### Phase 3: Cleanup old config

Remove the disabled MangoHud block from `home/home.nix:565-793` (the `programs.mangohud` block with the 130-app blacklist). Add `./mangohud.nix` to imports.

### Phase 4: Build and verify

1. `nix develop -c nix build .#nixosConfigurations.raider.config.system.build.toplevel`
2. `nix develop -c nix build .#nixosConfigurations.g14.config.system.build.toplevel`
3. Deploy to test machine and verify preset cycling works in an actual game

## Known Limitations

- **Gamepad toggle (antimicrox) doesn't work with Steam Input active** — keyboard toggle is the primary method for Steam games
- **Steam launch options are per-game** — no declarative global default; user adds `mangohud %command%` per game or uses SteamTinkerLaunch
- **GameScope session has its own overlay** — don't use MangoHud + GameScope overlay simultaneously
- **Flatpak launchers** (Lutris/Bottles Flatpak variants) may not support MangoHud injection — use native packages
- **OpenGL games on Wayland** — MangoHud uses LD_PRELOAD for OpenGL which can be unreliable under Xwayland

## Dependencies & Risks

- **MangoHud preset `no_display` behavior** — needs testing on current nixpkgs version. Fallback: use `toggle_hud` for show/hide + `toggle_preset` for visible levels only (2 keybinds instead of 1)
- **g14 NVIDIA PCI address** — hardcoded `0000:01:00.0`, verify against `hosts/g14/hardware-configuration.nix`

## Sources & References

- **Origin brainstorm:** [docs/brainstorms/2026-04-02-performance-osd-brainstorm.md](docs/brainstorms/2026-04-02-performance-osd-brainstorm.md) — per-game approach chosen over session-wide, 4-level cycling, both keyboard+gamepad toggle, part of gaming module
- Gaming module: `modules/constellation/gaming.nix:8-28` (option pattern), `186-207` (GameMode)
- Current disabled MangoHud: `home/home.nix:565-793`
- Home-manager osConfig pattern: `home/niri.nix:7-12`
- NVIDIA PRIME config: `hosts/g14/hardware-configuration.nix`
- nvidia-offload script: `home/home.nix:10-16`
