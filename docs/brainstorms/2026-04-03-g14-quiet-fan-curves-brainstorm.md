# Brainstorm: Quiet Fan Curves for G14

**Date:** 2026-04-03
**Status:** Complete

## What We're Building

Custom quiet fan curves for the ASUS ROG Zephyrus G14 (2020, AMD Ryzen 9 5900HS) to eliminate fan noise during idle/light use and reduce noise under load. The G14 hardware supports true 0 RPM operation, but the ASUS firmware defaults never use it — fans spin audibly even at 30°C.

### Goals

- Silent operation during browsing, coding, and light desktop use
- Smooth, gradual fan ramp under heavier loads (compilation, gaming)
- Fully declarative NixOS configuration (no manual `asusctl` commands)
- Willing to accept higher temps (up to 85-90°C) for quieter operation

## Why This Approach

### Chosen: Declarative fan curves via `services.asusd.fanCurvesConfig`

NixOS provides `services.asusd.fanCurvesConfig` which writes `/etc/asusd/fan_curves.ron` declaratively. This fits the NixOS model — the fan curve is version-controlled and reproducible across rebuilds.

### Alternatives considered

- **Platform profile "quiet" only**: Simpler (one-line TLP change) but firmware quiet mode still spins fans at idle. Not quiet enough.
- **Hybrid systemd oneshot**: More robust against asusd config-overwrite bugs, but introduces an imperative element. Can fall back to this if the declarative approach has reliability issues.

## Key Decisions

1. **Single quiet-by-default curve** — no profile switching. User prefers simplicity over multiple modes.
2. **"Gentle ramp" fan curve** — 0% below 65°C, smooth ramp to 100% at 100°C.
3. **Fix TLP conflict** — remove `PLATFORM_PROFILE_ON_AC/BAT` from TLP config to prevent it from resetting custom fan curves.
4. **Prioritize quiet over thermals** — accept temps up to 85-90°C under load.

## Fan Curve Values

Applied to the "Balanced" profile (since TLP currently uses `balanced`):

| Temp  | CPU Fan | GPU Fan |
|-------|---------|---------|
| 30°C  | 0%      | 0%      |
| 40°C  | 0%      | 0%      |
| 50°C  | 0%      | 0%      |
| 65°C  | 15%     | 10%     |
| 75°C  | 35%     | 30%     |
| 80°C  | 50%     | 45%     |
| 90°C  | 75%     | 70%     |
| 100°C | 100%    | 100%    |

**Rationale**: The 5900HS idles at 40-55°C. Zero fan below 65°C gives silence during light use. Gentle ramp from 65-80°C keeps noise low during moderate loads. Full speed at 100°C as safety net. GPU curve slightly lower since the dGPU is off most of the time (PRIME offload mode).

## Implementation Notes

### TLP conflict

Current TLP config has `PLATFORM_PROFILE_ON_AC = "balanced"` and `PLATFORM_PROFILE_ON_BAT = "balanced"`. Changing platform profile disables custom fan curves (ACPI firmware behavior). These settings must be removed or asusd must re-apply curves after each change.

### RON format

The `fan_curves.ron` file uses Rust Object Notation. The exact format is version-dependent. Best approach: boot with asusd to generate the default file, then modify the curve values and feed it back through `fanCurvesConfig`.

### Known risks

- **asusd config overwrite bug** (nixpkgs #453262): asusd may regenerate defaults on restart, clobbering NixOS-managed config. May need a systemd service to re-apply.
- **Curves disabled on profile switch**: If anything triggers a profile change, curves get disabled until asusd re-enables them.
- **Firmware minimum speed**: Some G14 BIOS versions enforce a minimum fan speed, silently overriding 0% requests. Testing required.
- **Curves reset after suspend**: asusd should re-apply on wake but this has been reported as unreliable.

### Fallback plan

If `fanCurvesConfig` proves unreliable, switch to a systemd oneshot service that runs `asusctl fan-curve` commands after asusd starts (Approach 3 from brainstorm).

## Open Questions

None — all questions resolved during brainstorm.

## References

- [asus-linux.org Fan Curves FAQ](https://asus-linux.org/faq/asusctl/custom-fan-curves/)
- [asusctl manual](https://github.com/flukejones/asusctl/blob/main/MANUAL.md)
- [NixOS asusd module source](https://github.com/NixOS/nixpkgs/blob/release-25.11/nixos/modules/services/hardware/asusd.nix)
- [nixpkgs #453262 — asusd config overwrite](https://github.com/NixOS/nixpkgs/issues/453262)
- Community curves from atrofac project, GitLab issues #203, #140, #58
