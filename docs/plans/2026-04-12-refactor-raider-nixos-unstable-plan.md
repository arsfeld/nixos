---
title: Switch Raider to NixOS Unstable
type: refactor
status: active
date: 2026-04-12
origin: docs/brainstorms/2026-04-12-raider-nixos-unstable-brainstorm.md
---

# Switch Raider to NixOS Unstable

## Overview

Switch raider from `nixos-25.11` (stable) to `nixos-unstable` as its primary nixpkgs, giving the desktop workstation access to the latest packages without per-package overlay workarounds. All other hosts (storage, cloud, g14, etc.) remain on stable.

This requires parameterizing `mkLinuxSystem` and the Colmena deployment path to support per-host nixpkgs selection, and adding a `home-manager-unstable` input to pair with the unstable nixpkgs.

## Problem Statement / Motivation

Raider currently cherry-picks individual packages from `nixpkgs-unstable` via overlays:
- `gamescope` in `hosts/raider/configuration.nix:64-72`
- `zed-editor`, `ghostty`, `multiviewer-for-f1` in `modules/constellation/gnome.nix:81-84`
- `ghostty`, `zed-editor` in `modules/constellation/niri.nix:78-81`

This is tedious to maintain and limits raider to only the explicitly listed packages. As a desktop workstation, raider benefits from the latest kernel, drivers, desktop environment, and applications.

(See brainstorm: `docs/brainstorms/2026-04-12-raider-nixos-unstable-brainstorm.md`)

## Proposed Solution

**Approach A from brainstorm:** Per-host nixpkgs override. Extend `mkLinuxSystem` to accept optional `nixpkgsInput` and `homeManagerInput` parameters (defaulting to stable). Raider opts into unstable via a simple hostname list in `hosts.nix`. Colmena gets a parallel update via its `nodeNixpkgs` mechanism.

## Technical Approach

### Architecture

Two parallel code paths construct NixOS configurations in this repo:

1. **`nixosConfigurations`** — `hosts.nix` → `mkLinuxSystem` → `nixpkgs.lib.nixosSystem`
2. **Colmena** — `colmena.nix` → `mkColmenaHost` → inline module composition with `meta.nixpkgs`

Both must be updated. `deploy-rs` and CI piggyback on `nixosConfigurations`, so they need no changes.

### Key Design Decisions

- **`home-manager-unstable` is required.** HM `release-25.11` tracks stable nixpkgs options. Using it with unstable nixpkgs risks module option mismatches. Add `home-manager-unstable` tracking `master` branch, following `nixpkgs-unstable`.
- **`nixpkgsInput` provides both `lib.nixosSystem` and the package set.** The parameterized input is used for `lib.nixosSystem` call, ensuring the module system uses the correct library version.
- **`baseModules` stays static.** The `lib` functions used (`flatten`, `mkDefault`) are identical between stable and unstable. No parameterization needed.
- **`homeManagerModules` becomes a function.** Computed inside `mkLinuxSystem` from the provided `homeManagerInput` parameter rather than being a static top-level binding.
- **Constellation module cleanup deferred.** The `pkgs-unstable` cherry-picks in `gnome.nix`/`niri.nix`/`cosmic.nix` become redundant on raider but still work (duplicate store paths, not broken). Clean up in a follow-up.
- **Simple hostname list for host selection.** `unstableHosts = ["raider"]` in `hosts.nix`. Convention-based file approach is over-engineering for one host.
- **Follows chains unchanged.** Inputs like disko, sops-nix, etc. continue following stable nixpkgs. They only use `lib` and are version-agnostic.

### Implementation Phases

#### Phase 1: Add Flake Inputs

**Goal:** Add `home-manager-unstable` input to `flake.nix`.

**Files:**
- `flake.nix` — Add input:
  ```nix
  home-manager-unstable = {
    url = "github:nix-community/home-manager";
    inputs.nixpkgs.follows = "nixpkgs-unstable";
  };
  ```

**Success criteria:** `nix flake lock` succeeds with new input resolved.

#### Phase 2: Parameterize `mkLinuxSystem`

**Goal:** Allow per-host nixpkgs and home-manager selection.

**File:** `flake-modules/lib.nix`

Current signature (line 80):
```nix
mkLinuxSystem = { mods, enableHomeManager ? true }:
  inputs.nixpkgs.lib.nixosSystem { ... };
```

New signature:
```nix
mkLinuxSystem = {
  mods,
  enableHomeManager ? true,
  nixpkgsInput ? inputs.nixpkgs,
  homeManagerInput ? inputs.home-manager,
}:
  nixpkgsInput.lib.nixosSystem {
    specialArgs = {inherit self inputs;};
    modules =
      baseModules
      ++ (if enableHomeManager then (homeManagerModulesFor homeManagerInput) else [])
      ++ mods;
  };
```

Where `homeManagerModulesFor` is a new helper that takes a home-manager input and returns the module list (replacing the static `homeManagerModules` binding at line 58-69). The existing `homeManagerModules` top-level export can call `homeManagerModulesFor inputs.home-manager` for backward compatibility.

**Success criteria:** All existing hosts build unchanged (they use defaults).

#### Phase 3: Wire Raider in `hosts.nix`

**Goal:** Pass unstable inputs for raider in the auto-discovery loop.

**File:** `flake-modules/hosts.nix`

Add a set like:
```nix
unstableHosts = ["raider"];
```

In the `mapAttrs` that calls `mkLinuxSystem`, conditionally pass:
```nix
nixpkgsInput = if builtins.elem name unstableHosts
  then inputs.nixpkgs-unstable
  else inputs.nixpkgs;
homeManagerInput = if builtins.elem name unstableHosts
  then inputs.home-manager-unstable
  else inputs.home-manager;
```

**Success criteria:** `nix build .#nixosConfigurations.raider.config.system.build.toplevel` builds against unstable. Other hosts still build against stable.

#### Phase 4: Update Colmena

**Goal:** Ensure Colmena deployment uses unstable for raider.

**File:** `flake-modules/colmena.nix`

1. Add raider to `nodeNixpkgs`:
   ```nix
   raider = import inputs.nixpkgs-unstable {
     system = "x86_64-linux";
     overlays = self.lib.overlays;
   };
   ```

2. Modify `mkColmenaHost` to accept and use `homeManagerInput` parameter (similar to Phase 2), or inline the correct home-manager module for unstable hosts.

**Success criteria:** `just deploy raider` succeeds (or `colmena build --on raider` if testing locally).

#### Phase 5: Clean Up Raider Overlays

**Goal:** Remove redundant unstable cherry-picks from raider's config.

**File:** `hosts/raider/configuration.nix`

- Remove the gamescope unstable overlay (lines 64-72) — gamescope comes from the system's unstable pkgs now
- Verify `nixpkgs.config.permittedInsecurePackages` for `mbedtls-2.28.10` (line 33) — check if the version string changed in unstable

**Success criteria:** Raider builds without the overlay. `gamescope` is present from base pkgs.

#### Phase 6: Verify All Hosts Build

**Goal:** Confirm no cross-host breakage.

**Commands:**
```bash
nix build .#nixosConfigurations.raider.config.system.build.toplevel
nix build .#nixosConfigurations.g14.config.system.build.toplevel
nix build .#nixosConfigurations.storage.config.system.build.toplevel
nix build .#nixosConfigurations.cloud.config.system.build.toplevel
```

**Success criteria:** All four hosts build successfully.

## System-Wide Impact

- **Interaction graph:** `mkLinuxSystem` is called by `hosts.nix` for all hosts. Colmena has a separate path. deploy-rs and CI inherit from `nixosConfigurations`.
- **Error propagation:** If unstable nixpkgs has a broken package, only raider's build fails. Other hosts are unaffected.
- **State lifecycle risks:** None — this is build-time configuration only. No runtime state changes.
- **API surface parity:** `mkLinuxSystem` gains optional parameters with backward-compatible defaults. No breaking changes to existing callers.

## Acceptance Criteria

### Functional Requirements

- [ ] Raider's `nixosConfigurations` evaluates against `nixpkgs-unstable`
- [ ] Raider's home-manager uses `home-manager-unstable` (master branch)
- [ ] All other hosts continue using `nixpkgs` (nixos-25.11) and `home-manager` (release-25.11)
- [ ] Colmena deployment for raider uses unstable nixpkgs
- [ ] Gamescope overlay removed from raider config
- [ ] All hosts (raider, g14, storage, cloud) build successfully

### Non-Functional Requirements

- [ ] `mkLinuxSystem` defaults are backward-compatible (no changes needed for stable hosts)
- [ ] No duplicate `import inputs.nixpkgs-unstable` in raider's evaluation (from the old overlay)

## Dependencies & Risks

**Risk: home-manager master incompatibility.** HM `master` tracks nixpkgs-unstable but may occasionally have broken commits. Mitigation: the flake.lock pins a specific HM commit — update intentionally.

**Risk: Unstable package breakage.** A package may be broken on unstable at any given time. Mitigation: pin `nixpkgs-unstable` via flake.lock, update intentionally with `nix flake update nixpkgs-unstable`.

**Risk: `permittedInsecurePackages` version mismatch.** The `mbedtls-2.28.10` string in raider's config may not match unstable's version. Mitigation: verify during build, update or remove as needed.

**Risk: Custom overlays/packages incompatible with unstable.** The `python-packages.nix` overlay and haumea-loaded packages are evaluated against the host's nixpkgs. Mitigation: verify all hosts build (Phase 6).

## Future Considerations

- **Constellation module optimization:** Remove redundant `pkgs-unstable` imports in `gnome.nix`/`niri.nix`/`cosmic.nix` for hosts already on unstable. Could accept an optional parameter or detect the nixpkgs version.
- **g14 migration:** If g14 also wants unstable in the future, just add it to `unstableHosts`.
- **CLAUDE.md update:** Document the dual-nixpkgs architecture so future work accounts for the split.

## Sources & References

### Origin

- **Brainstorm document:** [docs/brainstorms/2026-04-12-raider-nixos-unstable-brainstorm.md](docs/brainstorms/2026-04-12-raider-nixos-unstable-brainstorm.md) — Key decisions: raider-only scope, per-host nixpkgs override (Approach A), clean unstable with no fallback.

### Internal References

- `flake-modules/lib.nix:80-95` — `mkLinuxSystem` function
- `flake-modules/lib.nix:58-69` — `homeManagerModules` static binding
- `flake-modules/hosts.nix:13-27` — Host auto-discovery and `mkLinuxSystem` calls
- `flake-modules/colmena.nix:9-34` — `mkColmenaHost` separate code path
- `flake-modules/colmena.nix:48-57` — `nodeNixpkgs` per-host mechanism
- `flake-modules/colmena.nix:61` — `meta.nixpkgs` default
- `hosts/raider/configuration.nix:64-72` — Gamescope unstable overlay
- `hosts/raider/configuration.nix:33` — `permittedInsecurePackages`
- `modules/constellation/gnome.nix:81-84` — `pkgs-unstable` cherry-picks
- `modules/constellation/niri.nix:78-81` — `pkgs-unstable` cherry-picks
- `modules/constellation/cosmic.nix:36-39` — `pkgs-unstable` cherry-picks
- `.github/workflows/build.yml:79` — CI build command (no changes needed)
