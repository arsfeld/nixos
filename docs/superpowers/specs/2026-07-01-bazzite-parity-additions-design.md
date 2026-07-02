# Bazzite-parity additions for gaming + desktop modules

**Date:** 2026-07-01
**Scope:** Add a small set of Bazzite-GNOME-inspired tools to the shared
`constellation.gaming` and `constellation.desktop` modules. No host files
change. Reusable by every gaming/GNOME host; blackbird gets them immediately,
raider inherits them on its next deploy.

## Motivation

A comparison of Bazzite's GNOME image against blackbird found blackbird already
at or ahead of parity on most gaming/ASUS/NVIDIA fronts. The remaining
worthwhile gaps are a handful of packages and GNOME extensions. Placing them in
the shared modules (not host files) keeps blackbird and raider in sync.

## Changes

### `modules/constellation/gaming.nix`

Added to `environment.systemPackages`:

- `protonplus` — GUI Proton-GE / compat-tool manager. Unconditional.
  Complements the statically-baked `proton-ge-bin` (adds an in-GUI updater).
- `lsfg-vk` + `lsfg-vk-ui` — Lossless Scaling frame generation as a Vulkan
  implicit layer + its config GUI. GPU-vendor-agnostic (serves both blackbird's
  NVIDIA 1660 Ti and raider's AMD dGPU). Unconditional; the layer is inert until
  the user configures it. **Requires owning the paid "Lossless Scaling" Steam
  app** (`Lossless.dll`) to actually function — package is harmless without it.
- `ryzenadj` — AMD mobile TDP tuning. **Gated on `cpuVendor == "amd"`** so it
  lands on blackbird (Ryzen) and auto-skips raider (Intel). This gate is what
  makes it safe to live in the shared module.

### `modules/constellation/desktop.nix` (GNOME variant + shared base)

GNOME variant — added to `gnomeExtensions.*` packages **and** the dconf
`enabled-extensions` list (UUIDs verified against the flake's pinned nixpkgs):

| Attr | UUID |
|------|------|
| `burn-my-windows` | `burn-my-windows@schneegans.github.com` |
| `desktop-cube` | `desktop-cube@schneegans.github.com` |
| `compiz-windows-effect` | `compiz-windows-effect@hermes83.github.com` |
| `add-to-steam` | `add-to-steam@pupper.space` |
| `restart-to` | `restartto@tiagoporsch.github.io` |

GNOME variant — added to packages:
- `refine` — GTK4 tweak tool exposing experimental GNOME/mutter keys
  (VRR toggle etc.) that `gnome-tweaks` doesn't. Sits alongside `gnome-tweaks`.

Shared base — added to packages:
- `warehouse` — Flatpak lifecycle/rollback/data manager (DE-agnostic;
  complements Flatseal's permissions role). Flatpak is enabled in the shared
  base for all variants.

### Dropped from the original candidate list

- `bazaar-integration` — not in nixpkgs. Bazaar is already installed as a
  flatpak with logo-menu pointing at it, so no functionality lost.

### Deliberately unchanged

- `programs.gamemode` — **kept.** scx_lavd (`services.scx`) is a CPU scheduler
  only; gamemode adds screensaver-inhibit, I/O priority, and per-game GPU perf
  level (config already sets `nv_powermizer_mode`/`amd_performance_level`). They
  are complementary; Bazzite's removal was a distro-defaults opinion.
- FSR4 / decky-framegen — not applicable (RDNA4-only / Decky-Gaming-Mode-only)
  and not packaged.

## Verification

`nix build .#nixosConfigurations.blackbird.config.system.build.toplevel` builds
clean. (raider is offline; it builds on next deploy.)
