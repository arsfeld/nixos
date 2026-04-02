# Brainstorm: Installer ISO Cache Performance

**Date:** 2026-04-01
**Status:** Complete

## What We're Building

Speed up NixOS installation from the USB installer by ensuring `nixos-install` can fetch pre-built packages from the Attic binary cache instead of building from scratch.

## Problem

The installer ISO runs `nixos-install --flake .#g14` which is extremely slow because:

1. **g14 is not in the CI build matrix** — its closure is never pushed to Attic
2. **The installer ISO has no Attic substituter** — only `cache.nixos.org` is configured
3. **g14 uses `linuxPackages_zen`** — not cached anywhere, must build from source
4. **Harmonia on raider is not configured as a substituter** despite docs claiming it is (separate issue)

## Why This Approach

CI-first via Attic: build g14 in CI, push to Attic, configure the installer ISO to pull from Attic. This gives the fastest possible install regardless of LAN topology.

## Key Decisions

- **Add g14 to CI build matrix** in `.github/workflows/build.yml`
- **Switch g14 from zen to xanmod kernel** to match raider, maximizing shared cache hits and avoiding a custom kernel build in CI
- **Add Attic substituter to installer ISO** via `nix.settings` in `installer-iso.nix` (not via script NIX_CONFIG)
- **Only add g14** to CI for now (not other missing hosts)

## Changes Required

1. `installer-iso.nix` — add `nix.settings.substituters` and `trusted-public-keys` for Attic
2. `.github/workflows/build.yml` — add g14 to the matrix
3. `hosts/g14/configuration.nix` — remove `boot.kernelPackages = pkgs.linuxPackages_zen` (gaming.nix already sets xanmod)

## Open Questions

None — all decisions resolved.
