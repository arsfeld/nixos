---
title: Fix GNOME Wallpaper Discovery and Add Landscape Collections
type: fix
status: active
date: 2026-04-01
origin: docs/brainstorms/2026-04-01-gnome-landscape-wallpapers-brainstorm.md
---

# Fix GNOME Wallpaper Discovery and Add Landscape Collections

## Overview

Installed wallpaper packages (NixOS artwork, Fedora backgrounds, Pop!_OS) are not appearing in GNOME Settings > Appearance on raider/g14. External research confirmed GNOME 49 still uses the same `gnome-background-properties/*.xml` discovery mechanism via `XDG_DATA_DIRS` — the mechanism has not changed since GNOME 42. The issue is likely a stale session or an unverified on-disk state, plus known packaging bugs. Additionally, add landscape photography wallpaper collections from nixpkgs.

## Problem Statement

1. **Wallpaper packages invisible in GNOME picker** — 43 XML files are installed at `/run/current-system/sw/share/gnome-background-properties/` but only GNOME defaults show in Settings
2. **pop-hp-wallpapers broken** — XML references FHS paths (`/usr/share/backgrounds/pop-hp/...`) instead of Nix store paths; GNOME validates file existence and silently skips missing files
3. **elementary-wallpapers misplaced** — under `gnomeExtensions` conditional (line 280) instead of `wallpapers` conditional, and lacks `gnome-background-properties` XML entirely
4. **No landscape photography** — current wallpapers are mostly abstract/branded; user wants nature landscapes

## Proposed Solution

Three phases: diagnose, fix existing bugs, add landscape packages.

### Phase 1: Diagnose Discovery Issue

Verify on-disk state before making code changes. Run on raider:

```bash
# Check XML files exist
ls /run/current-system/sw/share/gnome-background-properties/

# Check XDG_DATA_DIRS includes the system profile
echo $XDG_DATA_DIRS | tr ':' '\n' | grep sw

# Verify image paths in XMLs are valid
for xml in /run/current-system/sw/share/gnome-background-properties/*.xml; do
  grep -oP '<filename>[^<]+</filename>' "$xml" | sed 's/<[^>]*>//g' | while read f; do
    [ ! -f "$f" ] && echo "MISSING: $f (in $xml)"
  done
done

# Then: log out of GNOME, log back in, check Settings > Appearance
```

**Expected outcome**: Wallpapers appear after fresh login. If not, `XDG_DATA_DIRS` debugging is needed.

### Phase 2: Fix Existing Bugs

**2a. Drop `pop-hp-wallpapers`** (line 333 of `gnome.nix`)

The package has hardcoded FHS paths in its XML and contributes ~196 MB of abstract/digital art (not landscapes). Rather than creating an overlay to fix the XML paths, simply remove it — the landscapes from budgie and Fedora f32 are better replacements.

**2b. Move `elementary-wallpapers`** from `gnomeExtensions` block to `wallpapers` block

Move `pantheon.elementary-wallpapers` from line 280 (inside `gnomeExtensions` conditional, lines 257-281) to the `wallpapers` conditional (lines 310-334). Note: this package lacks `gnome-background-properties` XML, so images won't appear in GNOME Settings picker, but they'll be available on disk for the wallpaper-slideshow extension or manual selection.

### Phase 3: Add Landscape Wallpaper Packages

Add to the `wallpapers` conditional in `gnome.nix`:

| Package | Landscapes | GNOME XML | Resolution | Size |
|---------|-----------|-----------|------------|------|
| `budgie-backgrounds` | ~9 (lakes, oceans, canyons, deserts, tea gardens) | Yes | 4K (3840x2160) | ~17 MB |
| `fedora-backgrounds.f32` | ~16 (lighthouses, mountains, sunsets, night sky) | Yes | 3K-5K mixed | ~164 MB |

Both packages ship correct `gnome-background-properties/*.xml` with absolute Nix store paths — they will appear in GNOME Settings immediately.

**Skipped**: `kdePackages.plasma-workspace-wallpapers` — best landscape collection (5K) but requires a custom GNOME XML wrapper derivation. Deferred to a follow-up if more landscapes are wanted (see brainstorm: `docs/brainstorms/2026-04-01-gnome-landscape-wallpapers-brainstorm.md`).

## Technical Considerations

- **Disk space**: Adding budgie + f32 adds ~181 MB. Removing pop-hp-wallpapers saves ~196 MB. Net change: **-15 MB**.
- **Both hosts affected**: raider and g14 both use `constellation.gnome` with `wallpapers = true` (default). The `wallpapers` option allows per-host override if g14 needs a smaller set.
- **striker excluded**: Uses raw GNOME (not `constellation.gnome`), intentionally out of scope.
- **variety vs wallpaper-slideshow**: Both are currently installed. They can coexist if only one is actively configured — no change needed here.

## Acceptance Criteria

- [x] `budgie-backgrounds` and `fedora-backgrounds.f32` added to `wallpapers` conditional in `modules/constellation/gnome.nix`
- [x] `pop-hp-wallpapers` removed from `wallpapers` conditional
- [x] `pantheon.elementary-wallpapers` moved from `gnomeExtensions` to `wallpapers` conditional
- [x] `nix build .#nixosConfigurations.raider.config.system.build.toplevel` succeeds
- [ ] After deploy + re-login: landscape wallpapers visible in GNOME Settings > Appearance

## Context

The file to modify is `modules/constellation/gnome.nix`:
- Lines 257-281: `gnomeExtensions` conditional (contains elementary-wallpapers at line 280)
- Lines 310-334: `wallpapers` conditional (add new packages here, remove pop-hp-wallpapers at line 333)

## MVP

### modules/constellation/gnome.nix

Move elementary-wallpapers, drop pop-hp, add landscapes:

```nix
# In the gnomeExtensions conditional (lines 257-281):
# REMOVE: pantheon.elementary-wallpapers (line 280)

# In the wallpapers conditional (lines 310-334):
# ADD these landscape packages:
budgie-backgrounds
fedora-backgrounds.f32
pantheon.elementary-wallpapers  # moved from gnomeExtensions block
# REMOVE: pop-hp-wallpapers (line 333)
```

## Sources

- **Origin brainstorm:** [docs/brainstorms/2026-04-01-gnome-landscape-wallpapers-brainstorm.md](docs/brainstorms/2026-04-01-gnome-landscape-wallpapers-brainstorm.md) — chose Approach 1 (fix discovery + add packaged collections), all nature landscapes, nixpkgs-only sources
- **GNOME wallpaper discovery code:** `gnome-control-center` `panels/background/cc-background-xml.c` reads `gnome-background-properties/*.xml` from `g_get_system_data_dirs()` — confirmed unchanged since GNOME 42
- **GNOME validates file existence:** `g_file_query_exists()` on each `<filename>` — silently skips missing files (explains pop-hp-wallpapers not rendering)
- Related file: `modules/constellation/gnome.nix:310-334` (wallpapers conditional)
