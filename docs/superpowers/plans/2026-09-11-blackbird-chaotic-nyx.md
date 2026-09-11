# Blackbird Chaotic-Nyx Kernel and NVIDIA Driver Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Migrate `blackbird` to the Chaotic-Nyx CachyOS BORE kernel (Linux 7.2.4) and NVIDIA 610.x driver (`nvidia_cachyos-bore`), leveraging prebuilt binary caches and aligning with `raider`'s kernel configuration.

**Architecture:** Import Chaotic-Nyx modules (`nyx-cache` and `nyx-overlay`) into `hosts/blackbird/configuration.nix`. Set `boot.kernelPackages` to `pkgs.linuxPackages_cachyos-bore` using `lib.mkForce` (mirroring `raider`). In `hosts/blackbird/hardware-configuration.nix`, configure `hardware.nvidia.package = pkgs.nvidia_cachyos-bore` and set `hardware.nvidia.open = false` to use the pre-cached CachyOS proprietary 610.x driver. Verify build locally using `nix-fast-build`.

**Tech Stack:** NixOS flakes, Chaotic-Nyx (`nyxpkgs-unstable`), CachyOS BORE kernel, NVIDIA 610.x Linux driver, `nix-fast-build`, `alejandra`.

**Spec:** User request to move `blackbird` to Chaotic-Nyx for stability improvements with newer kernel and drivers.

## Global Constraints
- Flake lock and module conventions: import `nyx-cache` and `nyx-overlay` from `inputs.chaotic.nixosModules` without `nyx-registry` (which collides with `common.nix`).
- Conventional commits required: `feat(blackbird): ...` without mentioning AI or assistants.
- Alejandra formatting required: all modified files must pass `just fmt` (`nix run nixpkgs#alejandra -- --check .`).
- Build testing: use `nix-fast-build` for local evaluation and building.

---

### Task 1: Update Blackbird Configuration and Hardware Configuration

**Files:**
- Modify: `hosts/blackbird/configuration.nix`
- Modify: `hosts/blackbird/hardware-configuration.nix`

**Interfaces:**
- Consumes: `inputs.chaotic.nixosModules.nyx-cache`, `inputs.chaotic.nixosModules.nyx-overlay`, `pkgs.linuxPackages_cachyos-bore`, `pkgs.nvidia_cachyos-bore`
- Produces: `nixosConfigurations.blackbird.config.system.build.toplevel`

- [x] **Step 1: Verify `inputs` is in scope in `hosts/blackbird/configuration.nix`**

Check line 1 of `hosts/blackbird/configuration.nix` and ensure `inputs` is in the function signature:
```nix
{
  config,
  pkgs,
  lib,
  inputs,
  ...
}:
```

- [x] **Step 2: Add Chaotic-Nyx imports and kernel package override in `hosts/blackbird/configuration.nix`**

Add `inputs.chaotic.nixosModules.nyx-overlay` to `imports` (with `nyx-cache` now globally in `common.nix`).
Update `boot.kernelPackages` to:
```nix
  # CachyOS BORE kernel from Chaotic-Nyx, mirroring raider.
  boot.kernelPackages = lib.mkForce pkgs.linuxPackages_cachyos-bore;
```

- [x] **Step 3: Update `hosts/blackbird/hardware-configuration.nix` to use `pkgs.nvidia_cachyos-bore`**

Update `hardware.nvidia`:
```nix
    open = false;
    nvidiaSettings = true;
    package = pkgs.nvidia_cachyos-bore;
```

- [x] **Step 4: Format with Alejandra**

Run: `just fmt`
Expected: "Congratulations! Your code complies with the Alejandra style."

- [x] **Step 5: Build and verify using `nix-fast-build`**

Run:
```bash
nix-fast-build --flake '.#deployTargets' --select 't: { inherit (t) blackbird; }' --no-nom
```
Expected: Evaluates and builds `blackbird` successfully with exit code 0.

- [x] **Step 6: Run Flake checks**

Run:
```bash
nix build .#checks.x86_64-linux.blackbird-audio-control-test
```
Expected: PASS with exit code 0.

- [ ] **Step 7: Commit changes**

```bash
git add hosts/blackbird/configuration.nix hosts/blackbird/hardware-configuration.nix
git commit -m "feat(blackbird): move to Chaotic-Nyx CachyOS BORE kernel and NVIDIA 610.x"
```

---

### Task 2: Push to Remote and Verify CI

**Files:**
- Remote: `origin/master`
- Workflows: `.github/workflows/build.yml`, `.github/workflows/format.yml`

- [x] **Step 1: Push commit to `origin/master`**

Run: `git push origin master`

- [x] **Step 2: Monitor GitHub Actions CI runs**

Run: `gh run list --limit 4`
Verify:
- `Format Check`: Success
- `Build & Cache`: All hosts including `blackbird` succeed
