# Brainstorm: GNOME Landscape Wallpapers

**Date:** 2026-04-01
**Status:** Draft

## What We're Building

Fix GNOME wallpaper discovery so that installed wallpaper packages (NixOS artwork, Fedora backgrounds, Pop!_OS, etc.) actually appear in GNOME Settings > Appearance, and add more landscape-heavy wallpaper collections from nixpkgs.

### Problem Statement

The GNOME module (`modules/constellation/gnome.nix`) installs wallpaper packages via `environment.systemPackages` when `constellation.gnome.wallpapers = true`. These packages include proper `gnome-background-properties/*.xml` metadata. However, only GNOME's built-in default wallpapers appear in the Settings > Appearance wallpaper picker. The extra packages (NixOS artwork, Fedora backgrounds, Pop!_OS) are invisible.

This is on GNOME 49 (NixOS 25.11). Recent GNOME versions have significantly reworked the wallpaper picker, which may have changed how wallpapers are discovered.

### Goals

1. **Fix discovery**: Make all installed wallpaper packages visible in GNOME's wallpaper picker
2. **Add landscapes**: Include more landscape photography wallpaper collections from nixpkgs
3. **Keep it declarative**: All wallpapers managed via Nix, no manual file placement

## Why This Approach

- **Approach 1 (Fix discovery + add packaged collections)** was chosen over creating custom derivations or using `variety` because:
  - Stays within nixpkgs ecosystem — clean and maintainable
  - Fixes a real bug affecting all the existing wallpaper packages
  - Landscape photography exists in several nixpkgs wallpaper packages (Fedora backgrounds, GNOME backgrounds, potentially MATE/deepin)
  - No extra daemons or external dependencies

- **Rejected alternatives:**
  - Custom derivation bundling images: more maintenance, need to source/license images
  - `variety` wallpaper manager: extra daemon, doesn't integrate with GNOME Settings
  - Dynamic/online sources: requires network, non-deterministic

## Key Decisions

- **Source**: Use existing nixpkgs wallpaper packages only (no custom image bundling)
- **Discovery fix**: Investigate GNOME 49's wallpaper discovery mechanism and adapt the installation method accordingly (may need `gnome.gnome-backgrounds` override, different XML format, or a wrapper)
- **Scope**: Focus on `raider` host (primary GNOME desktop), but fix applies to all GNOME hosts
- **Elementary wallpapers**: These lack `gnome-background-properties` XML — may need a wrapper package or should be dropped from the GNOME wallpaper list
- **Landscape style**: All nature landscapes (mountains, forests, oceans, deserts, aurora, night skies — no specific preference, just high-quality photography)
- **Diagnosis needed**: Haven't yet verified on-disk state — need to check whether wallpaper XML files actually exist at `/run/current-system/sw/share/gnome-background-properties/` and whether `constellation.gnome.wallpapers` is enabled on raider

## Open Questions (to resolve during planning)

1. **What changed in GNOME 49's wallpaper discovery?** — Need to investigate whether GNOME 49 still reads `gnome-background-properties` XML from `XDG_DATA_DIRS`, or if a new mechanism is required
2. **Which additional nixpkgs packages have landscape photography?** — Need to evaluate `gnome-backgrounds`, MATE backgrounds, deepin wallpapers, and Ubuntu wallpapers for landscape content availability in nixpkgs 25.11
3. **Is the issue XDG_DATA_DIRS or XML format?** — The installed packages may be in the right place but using an incompatible XML schema for GNOME 49
4. **Is `constellation.gnome.wallpapers` actually enabled on raider?** — Need to verify the option is set in the host config
