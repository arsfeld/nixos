# Brainstorm: Switch Raider to NixOS Unstable

**Date:** 2026-04-12
**Status:** Draft

## What We're Building

Switch the raider desktop host from nixos-25.11 (stable) to nixos-unstable as its primary nixpkgs input. This gives raider access to the latest package versions (desktop environment, drivers, kernel, apps) without needing per-package overlay workarounds.

**Scope:** Raider only. Servers (storage, cloud) and other hosts remain on stable 25.11.

## Why This Approach

**Motivation:** Newer package versions for the desktop workstation. Raider already cherry-picks unstable packages via overlays (e.g., gamescope). Moving the whole system to unstable eliminates this piecemeal approach and provides consistently up-to-date software.

**Approach chosen:** Per-host nixpkgs override (Approach A). Keep stable as the default for all hosts, but allow individual hosts to specify an alternative nixpkgs. Raider opts into unstable; everything else stays on stable by default.

**Why not flip the default?** Servers benefit from stable's predictability. Making unstable the default inverts the safety model — servers should get the safe default without explicit overrides.

## Key Decisions

1. **Raider-only scope** — no other hosts change nixpkgs
2. **Approach A: per-host nixpkgs override** — extend `mkLinuxSystem` to accept an optional nixpkgs parameter, defaulting to stable
3. **Clean unstable** — no stable fallback overlay on raider; if something breaks, wait for upstream fix or patch it
4. **Remove raider's unstable overlays** — gamescope and any other cherry-picked unstable packages become unnecessary once the whole system is unstable

## Open Questions

1. **Shared flake inputs compatibility** — Home-manager, niri, and other flake inputs currently `follows = "nixpkgs"` (stable). When raider evaluates against unstable nixpkgs, will these inputs work correctly? **To research during planning phase** — investigate what actually needs to change before committing to duplicate inputs.

2. **CI builds** — The GitHub Actions workflow builds raider on nixos-25.11. Switching raider to unstable may affect build caching and CI evaluation time.

## Resolved Questions

- **Shared constellation modules** — Expected to be compatible across stable/unstable. These are high-level option modules unlikely to break.

## Implementation Sketch (High-Level)

- Modify `flake-modules/lib.nix`: `mkLinuxSystem` accepts optional `nixpkgs` parameter (defaults to `inputs.nixpkgs`)
- Modify `flake-modules/hosts.nix`: allow per-host nixpkgs specification (e.g., via a convention like a `nixpkgs.nix` file in the host directory, or a simple attribute)
- Update `hosts/raider/configuration.nix`: remove unstable overlays that become redundant
- Possibly add duplicate inputs for home-manager-unstable (pending research)
- Update CI if needed
