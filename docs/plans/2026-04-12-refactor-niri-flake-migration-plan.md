---
title: Migrate niri to niri-flake with modernized compositor stack
type: refactor
status: completed
date: 2026-04-12
---

# Migrate niri to niri-flake with modernized compositor stack

## Overview

Replace the nixpkgs built-in `programs.niri` module with [niri-flake](https://github.com/sodiboo/niri-flake) for declarative, build-time-validated niri configuration in Nix. Simultaneously modernize the compositor tool stack by replacing stale/deprecated tools (eww, polkit_gnome, swaylock-effects, anyrun) with actively maintained alternatives (waybar, mate-polkit).

## Problem Statement / Motivation

The current niri setup has two problems:

1. **Raw KDL configuration** (`home/niri.nix` lines 15-266) is a 250-line string blob with no build-time validation. Typos in KDL are only caught at runtime when niri fails to start. niri-flake provides `programs.niri.settings` — a typed Nix attrset that validates at `nix build` time.

2. **Stale tool stack** — several compositor tools are unmaintained or deprecated:
   - **eww** (status bar): Last release Apr 2024, stalled development, no native niri support
   - **polkit_gnome**: Unmaintained for 12+ years, deprecated by GNOME itself
   - **swaylock-effects**: Unmaintained, all forks abandoned
   - **anyrun**: Maintenance mode, no formal release

## Proposed Solution

### Flake Integration

Add `niri-flake` as a flake input. Its NixOS module replaces nixpkgs' `programs/niri.nix` (via `disabledModules`) and auto-imports Home Manager modules for all HM users.

### Tool Replacements

| Remove | Replace With | Reason |
|--------|-------------|--------|
| eww | **waybar** | Native `niri/workspaces`, `niri/window`, `niri/language` modules via IPC. No polling. Niri's own default config uses waybar. Home Manager `programs.waybar` module. |
| polkit_gnome | **mate.mate-polkit** | GTK-based, actively maintained, respects dark themes. Recommended by niri community. |
| swaylock-effects | *(drop)* | Current swaylock config uses no effects-specific features. Plain swaylock (v1.8.5, maintained) is sufficient. |
| anyrun | *(drop)* | fuzzel is the community default, already configured, already bound to Mod+Space/Mod+D. |
| xfce.thunar + plugins | *(drop)* | Redundant — nautilus already included via `includeGnomeApps`. Required by `xdg-desktop-portal-gnome` for file chooser. |
| pamixer | *(drop)* | Keybindings already use `wpctl` (PipeWire-native). |
| wf-recorder | *(drop)* | `wl-screenrec` (kept) is hardware-accelerated and preferred by community. |

### Niri Built-in Features (v25.08+)

- **xwayland-satellite**: Auto-managed by niri since v25.08. Remove `spawn-at-startup "xwayland-satellite"` (keep the package installed).
- **Screenshots**: Built-in interactive UI for region/window/monitor capture. Keep grim+slurp+swappy for annotation workflows.
- **Overview**: Built-in workspace overview (v25.05). No external tool needed.

### Known Regression: Dock

The eww config provides a macOS-style animated dock at the bottom of the screen. Waybar is strictly a bar and cannot replicate this. **The dock is intentionally dropped** for this migration. If a dock is desired later, options include `nwg-dock-hyprland` or a minimal standalone eww instance.

## Technical Considerations

### niri-flake's NixOS module is global

When added to `baseModules`, the niri-flake module affects ALL hosts:
- Calls `disabledModules = [ "programs/niri.nix" ]` unconditionally — removes nixpkgs' niri module from every host
- Auto-adds `niri.cachix.org` to `nix.settings.substituters` on every host (disable with `niri-flake.cache.enable = false`)
- Auto-imports `homeModules.config` for all Home Manager users

**Mitigation**: Disable the cachix cache globally and only enable it on desktop hosts. The `disabledModules` is harmless since no server host uses `programs.niri`. The HM auto-import is also harmless since `programs.niri.settings` is opt-in.

### No `nixpkgs.follows` support

niri-flake pins its own nixpkgs internally. However, the **overlay** (`overlays.niri`) builds niri against YOUR nixpkgs, ensuring mesa and other graphics dependencies match. The internal nixpkgs is only used for the flake's CI. Practical impact on evaluation time should be minimal since the niri packages come from the overlay, not from the flake's internal nixpkgs evaluation.

### Home Manager auto-import

The NixOS module auto-imports `homeModules.config` for all HM users. This makes `programs.niri.settings` available but does NOT activate anything — the options are purely opt-in. The existing `mkIf niriEnabled` guard in `home/niri.nix` remains the activation mechanism.

### Display manager mutual exclusion

GNOME uses GDM, niri defaults to greetd. Both cannot be active simultaneously. Add an assertion to prevent dual-enablement.

## System-Wide Impact

- **All hosts**: niri-flake NixOS module loaded (but inactive unless `programs.niri.enable = true`)
- **Desktop hosts** (raider, g14): Can enable niri via `constellation.niri.enable = true`
- **Server/embedded hosts**: No functional change — module options exist but are unused
- **CI**: Additional flake input to fetch/lock. Minimal evaluation overhead since niri packages are opt-in.
- **Binary cache**: Disable `niri-flake.cache.enable` globally; enable only on desktop hosts

## Acceptance Criteria

### Phase 1: Flake Wiring
- [x] `niri.url = "github:sodiboo/niri-flake"` added to `flake.nix`
- [x] `inputs.niri.nixosModules.niri` added to `baseModules` in `flake-modules/lib.nix`
- [x] `niri-flake.cache.enable = false` set in `baseModules` to prevent global cachix addition
- [x] All hosts build successfully: `nix build .#nixosConfigurations.<host>.config.system.build.toplevel` for raider, g14, storage, cloud
- [x] `flake.lock` updated

### Phase 2: NixOS Module Update
- [x] `modules/constellation/niri.nix` updated:
  - Remove: eww, anyrun, swaylock-effects, polkit_gnome, xfce.thunar + plugins, pamixer, wf-recorder
  - Add: waybar, mate.mate-polkit
  - Add niri-flake overlay: `nixpkgs.overlays = [ inputs.niri.overlays.niri ];`
  - Enable cachix on niri hosts: `niri-flake.cache.enable = true`
  - Keep PipeWire/bluetooth/networkmanager (niri needs them explicitly, unlike GNOME)
- [x] Add mutual exclusion assertion between niri, GNOME, and COSMIC
- [x] All hosts still build

### Phase 3: Home Manager Rewrite
- [x] `home/home.nix` — add `./niri.nix` to imports
- [x] `home/niri.nix` — rewrite:
  - Replace raw KDL (`xdg.configFile."niri/config.kdl"`) with `programs.niri.settings`
  - Replace eww bar/dock with `programs.waybar` (settings + style)
  - Remove anyrun config entirely
  - Remove `spawn-at-startup "xwayland-satellite"` (auto-managed)
  - Replace polkit_gnome spawn with mate.mate-polkit
  - Keep: mako config, swaylock config, swayidle config, fuzzel config, GTK/Qt theming
- [x] All hosts build
- [x] Config validated: system toplevel evaluates successfully with niri enabled

### Phase 4: Activation Testing (on raider)
- [ ] Set `constellation.niri.enable = true` (and `gnome.enable = false`) on raider
- [ ] Build and deploy: `just test raider`
- [ ] Verify: display manager starts, niri session available
- [ ] Verify: waybar renders with niri/workspaces + niri/window modules
- [ ] Verify: XWayland apps work (Steam, Electron apps)
- [ ] Verify: polkit authentication dialog appears on privilege escalation
- [ ] Verify: screen locking (Mod+Escape), idle timeout, media keys
- [ ] Verify: fuzzel launches (Mod+Space), screenshots work (Print)

## Files to Modify

| File | Change |
|------|--------|
| `flake.nix:28` | Add `niri.url` input |
| `flake-modules/lib.nix:28-54` | Add `inputs.niri.nixosModules.niri` to `baseModules`, disable cachix globally |
| `modules/constellation/niri.nix` | Update package list, add overlay, add DE mutual exclusion assertion, enable cachix |
| `home/home.nix:28-33` | Add `./niri.nix` to imports list |
| `home/niri.nix` | Full rewrite: KDL -> `programs.niri.settings`, eww -> `programs.waybar`, remove anyrun |

## Dependencies & Risks

**Dependencies:**
- niri-flake must provide niri-stable >= v25.08 (for auto xwayland-satellite)
- waybar must have `niri/workspaces` module support (confirmed in Waybar v0.10+)

**Risks:**
- **Build breakage on non-desktop hosts**: Mitigated by Phase 1 verification step (build all hosts before proceeding)
- **Visual regression**: Dock loss is intentional. Waybar styling should match WhiteSur theme.
- **niri-flake abandonment**: Creates hard dependency on external flake. Reverting requires rewriting `programs.niri.settings` back to raw KDL. Mitigated by niri-flake's active development and large user base.
- **Dual DE conflict**: Mitigated by assertion. User must disable GNOME before enabling niri.

## Sources & References

### Internal References
- Current niri NixOS module: `modules/constellation/niri.nix`
- Current niri HM config: `home/niri.nix` (not currently imported in `home/home.nix`)
- Flake input pattern: `flake.nix:1-29`
- baseModules definition: `flake-modules/lib.nix:28-54`
- homeManagerModules: `flake-modules/lib.nix:56-67`

### External References
- [niri-flake GitHub](https://github.com/sodiboo/niri-flake) — README, docs.md
- [niri-flake docs.md](https://github.com/sodiboo/niri-flake/blob/main/docs.md) — settings API reference
- [niri releases](https://github.com/niri-wm/niri/releases) — v25.08 (xwayland auto), v25.11 (latest)
- [niri Important Software wiki](https://github.com/niri-wm/niri/wiki/Important-Software) — recommended tools
- [Waybar niri modules](https://github.com/Alexays/Waybar/wiki/Module:-Niri) — native workspace/window/language support
- [Home Manager waybar module](https://mynixos.com/home-manager/options/programs.waybar) — declarative config
- [NixOS Wiki: Niri](https://wiki.nixos.org/wiki/Niri) — NixOS-specific integration notes
