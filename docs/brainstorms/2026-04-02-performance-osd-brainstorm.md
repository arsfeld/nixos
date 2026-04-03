# Performance OSD Brainstorm

**Date:** 2026-04-02
**Status:** Complete

## What We're Building

A Steam Deck-style performance overlay (OSD) for gaming on raider and g14 machines. The overlay displays FPS, frametime graph, CPU/GPU usage, temperatures, and power draw — with 4 cycling levels and both keyboard and gamepad toggle support.

The overlay loads only for games (not system-wide), using MangoHud's per-game loader approach via Steam launch options, Lutris runner settings, and manual `mangohud` wrapper.

## Why This Approach

**MangoHud per-game loader** was chosen over two alternatives:

- **Session-wide + no_display:** Loads MangoHud into ALL Vulkan/GL apps (browsers, file managers) even when hidden. Tiny perf overhead and risk of accidental display in non-game apps.
- **GameScope nested compositor:** Authentic Steam Deck experience but adds a compositor layer, has GNOME compatibility concerns, and doesn't work easily for non-Steam games.

Per-game loading is the cleanest approach: MangoHud never touches non-game apps, no blacklist maintenance needed, and works reliably on GNOME Wayland.

## Key Decisions

### Overlay Levels (4-level cycle)
1. **Level 0 — OFF** (default on game start): Hidden, no display
2. **Level 1 — FPS only**: Small counter in corner
3. **Level 2 — Detail**: FPS + CPU/GPU usage %, GPU temp, power draw
4. **Level 3 — Full**: Frametime graph, per-core CPU, VRAM, RAM, battery (g14)

### Activation Method
- **Per-game only** — not session-wide, not enableSessionWide
- Steam: `mangohud %command%` as default launch option
- Lutris: MangoHud enabled in runner options
- Manual: `mangohud ./game` wrapper

### Toggle Methods
- **Keyboard:** Keybind to cycle overlay levels (e.g., Shift_R+F12)
- **Gamepad:** Controller button combo mapped via antimicrox to same keybind

### Position & Appearance
- **Position:** Top-left
- **Style:** Semi-transparent background, readable font size
- **Default state:** Hidden (level 0) — user presses keybind to reveal

### Module Integration
- Added to existing `constellation.gaming` module (not a separate module)
- New sub-option: `constellation.gaming.performanceOsd` (default: true when gaming is enabled)
- MangoHud configuration via home-manager (replaces the disabled config in home.nix)
- Old MangoHud config + blacklist in home.nix to be removed

### Hardware Considerations
- **Raider:** Intel iGPU + AMD dGPU — overlay targets AMD GPU metrics
- **G14:** AMD iGPU + NVIDIA dGPU — overlay targets NVIDIA GPU metrics via PRIME
- Battery/power metrics relevant on g14 (laptop), less so on raider (desktop)

## Open Questions

_None — all resolved during brainstorm._

## Out of Scope

- GameScope integration (can be explored later)
- Custom overlay themes/skins
- Recording/streaming overlay (gpu-screen-recorder is separate)
- Per-game overlay profiles
