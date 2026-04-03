---
title: "feat(g14): Add quiet custom fan curves via asusd"
type: feat
status: active
date: 2026-04-03
origin: docs/brainstorms/2026-04-03-g14-quiet-fan-curves-brainstorm.md
---

# feat(g14): Add quiet custom fan curves via asusd

## Overview

Configure custom quiet fan curves for the ASUS G14 via `services.asusd.fanCurvesConfig`, eliminating fan noise during idle/light use and providing a smooth ramp under load. Fix the TLP platform profile conflict and clean up thermald (unnecessary on AMD).

(see brainstorm: docs/brainstorms/2026-04-03-g14-quiet-fan-curves-brainstorm.md)

## Problem Statement

The G14's firmware fan curves are aggressively conservative — fans spin audibly (~11% PWM) even at 30°C idle. The hardware supports true 0 RPM but the defaults never use it. The user wants silent operation during browsing/coding and is willing to accept higher temps (up to 85-90°C) for quiet.

## Proposed Solution

Three changes to `hosts/g14/configuration.nix`:

1. **Add `fanCurvesConfig`** to `services.asusd` with a "gentle ramp" curve: 0% below 65°C, smooth ramp to 100% at 100°C
2. **Remove `PLATFORM_PROFILE_ON_AC/BAT`** from TLP settings (they reset custom fan curves on every profile change)
3. **Disable thermald** — it's an Intel daemon, unnecessary/potentially conflicting on AMD Ryzen

Optional hardening: add a systemd resume hook to re-apply curves after suspend/hibernate.

## Technical Considerations

### Fan Curve Values (PWM 0-255)

Applied to the `balanced` profile only. Performance/quiet/custom profiles left empty (firmware defaults).

| Temp  | CPU Fan (%) | CPU PWM | GPU Fan (%) | GPU PWM |
|-------|-------------|---------|-------------|---------|
| 30°C  | 0%          | 0       | 0%          | 0       |
| 40°C  | 0%          | 0       | 0%          | 0       |
| 50°C  | 0%          | 0       | 0%          | 0       |
| 65°C  | 15%         | 38      | 10%         | 26      |
| 75°C  | 35%         | 89      | 30%         | 77      |
| 80°C  | 50%         | 128     | 45%         | 115     |
| 90°C  | 75%         | 191     | 70%         | 179     |
| 100°C | 100%        | 255     | 100%        | 255     |

### RON Format (asusctl 6.1.17)

The `fan_curves.ron` file uses Rust Object Notation. Structure from source (`rog-profiles/src/fan_curve_set.rs`):

```ron
(
    profiles: (
        balanced: [
            (
                fan: CPU,
                pwm: (0, 0, 0, 38, 89, 128, 191, 255),
                temp: (30, 40, 50, 65, 75, 80, 90, 100),
                enabled: true,
            ),
            (
                fan: GPU,
                pwm: (0, 0, 0, 26, 77, 115, 179, 255),
                temp: (30, 40, 50, 65, 75, 80, 90, 100),
                enabled: true,
            ),
        ],
        performance: [],
        quiet: [],
        custom: [],
    ),
)
```

**Critical**: `enabled: true` must be set per entry, otherwise curves are stored but not applied.

### NixOS Module Interface

From `nixos/modules/services/hardware/asusd.nix` (lines 98-105):

```nix
services.asusd.fanCurvesConfig = {
  text = ''
    ... RON content ...
  '';
};
```

Writes to `/etc/asusd/fan_curves.ron` via `environment.etc` (symlink to Nix store, mode 0644).

### TLP Conflict

Current lines 197-198 in `hosts/g14/configuration.nix`:
```nix
PLATFORM_PROFILE_ON_AC = "balanced";
PLATFORM_PROFILE_ON_BAT = "balanced";
```

These trigger ACPI profile changes that disable custom fan curves. Must be removed. Add a comment explaining why.

### thermald on AMD

`services.thermald.enable = true` (line 245) is an Intel thermal daemon — unnecessary on the AMD Ryzen 5900HS. It could interfere with ACPI thermal zones that asusd relies on. Should be disabled.

### Known Risks

| Risk | Likelihood | Mitigation |
|------|-----------|------------|
| asusd overwrites NixOS config on restart (nixpkgs #453262) | Medium | NixOS `environment.etc` creates read-only symlinks — asusd can't overwrite. If it fails to start, fall back to systemd oneshot approach |
| Fan curves lost after suspend/resume | Medium | Test first. If needed, add systemd resume hook: `asusctl fan-curve -m Balanced -f cpu -e true` |
| Firmware enforces minimum fan speed | Low | Test on actual hardware. 0 RPM is hardware-supported on G14 2020 |
| dGPU power on/off resets curves | Low | PRIME offload power management is separate from platform profile. Verify during testing |
| RON format mismatch with asusctl version | Low | Format derived from asusctl 6.1.17 source. If build fails, generate default on device and adapt |

### Fallback Plan

If `fanCurvesConfig` proves unreliable, switch to a systemd oneshot service that runs `asusctl fan-curve` commands after asusd starts (see brainstorm: Approach 3).

## Acceptance Criteria

- [ ] Fans are silent at idle/light desktop use (temps below 65°C)
- [ ] Fans ramp smoothly under load (no sudden jumps)
- [x] Configuration is fully declarative in `hosts/g14/configuration.nix`
- [x] `PLATFORM_PROFILE_ON_AC/BAT` removed from TLP (with explanatory comment)
- [x] `thermald` disabled
- [x] NixOS build succeeds: `nix build .#nixosConfigurations.g14.config.system.build.toplevel`
- [ ] Post-deploy verification: `asusctl fan-curve --show` shows `enabled: true` for balanced profile

## MVP

### hosts/g14/configuration.nix

Three changes in this file:

**1. Add `fanCurvesConfig` to `services.asusd` block (after line 82):**

```nix
services.asusd = {
  enable = true;
  enableUserService = true;
  fanCurvesConfig = {
    text = ''
      (
          profiles: (
              balanced: [
                  (
                      fan: CPU,
                      pwm: (0, 0, 0, 38, 89, 128, 191, 255),
                      temp: (30, 40, 50, 65, 75, 80, 90, 100),
                      enabled: true,
                  ),
                  (
                      fan: GPU,
                      pwm: (0, 0, 0, 26, 77, 115, 179, 255),
                      temp: (30, 40, 50, 65, 75, 80, 90, 100),
                      enabled: true,
                  ),
              ],
              performance: [],
              quiet: [],
              custom: [],
          ),
      )
    '';
  };
};
```

**2. Remove `PLATFORM_PROFILE_ON_AC/BAT` from TLP settings (lines 197-198), add comment:**

```nix
services.tlp.settings = {
  # ...
  # PLATFORM_PROFILE removed: changing platform profile via TLP
  # disables asusd custom fan curves (ACPI firmware behavior)
  # ...
};
```

**3. Disable thermald (line 245):**

```nix
services.thermald.enable = false;  # Intel daemon, unnecessary on AMD Ryzen
```

## Testing Procedure

1. Build locally: `nix build .#nixosConfigurations.g14.config.system.build.toplevel`
2. Deploy: `just deploy g14`
3. Verify curves active: `asusctl fan-curve --show` — check `enabled: true` for balanced CPU/GPU
4. Idle test: monitor temps with `sensors` — fans should be silent below 65°C
5. Load test: run `stress-ng --cpu 8 --timeout 60s` — fans should ramp smoothly, no sudden jumps
6. Suspend/resume test: close and reopen lid, verify curves still active with `asusctl fan-curve --show`
7. If suspend loses curves: add systemd resume hook (see fallback in Technical Considerations)

## Sources

- **Origin brainstorm:** [docs/brainstorms/2026-04-03-g14-quiet-fan-curves-brainstorm.md](docs/brainstorms/2026-04-03-g14-quiet-fan-curves-brainstorm.md) — key decisions: declarative fanCurvesConfig approach, gentle ramp curve values, single balanced profile, TLP conflict fix
- NixOS asusd module: `nixos/modules/services/hardware/asusd.nix` (nixpkgs)
- asusctl 6.1.17 source: `rog-profiles/src/fan_curve_set.rs`, `asusd/src/ctrl_fancurves.rs`
- Community fan curves: atrofac project, asus-linux GitLab issues #203, #140, #58
- [asus-linux.org Fan Curves FAQ](https://asus-linux.org/faq/asusctl/custom-fan-curves/)
