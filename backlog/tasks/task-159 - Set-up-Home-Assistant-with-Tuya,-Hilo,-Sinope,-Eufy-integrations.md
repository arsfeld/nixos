---
id: task-159
title: 'Set up Home Assistant with Tuya, Hilo, Sinope, Eufy integrations'
status: To Do
assignee: []
created_date: '2025-12-15 03:09'
updated_date: '2025-12-15 04:12'
labels:
  - home-assistant
  - storage
  - automation
dependencies: []
priority: medium
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Set up Home Assistant on storage host using the native NixOS `services.home-assistant` module with constellation pattern. Migrate from container-based deployment to declarative NixOS configuration.

**Approach:**
- Create `modules/constellation/home-assistant.nix` module
- Use `services.home-assistant` with declarative config
- Use nixpkgs custom components where available (tuya_local, alarmo)
- Use HACS for remaining integrations (hilo, neviweb130, eufy_security, powercalc, pirate_weather)
- Define automations declaratively in NixOS

**Available in nixpkgs:**
- tuya_local (v2025.12.0) - Heat pump control
- alarmo (v1.10.12) - Alarm system

**Requires HACS:**
- hilo (dvd-dev/hilo) - Hydro-Québec challenges (flex d rate)
- neviweb130 (claudegel/sinope-130) - WiFi thermostats
- eufy_security (fuatakgun/eufy_security) - Cameras/doorbells
- powercalc - Energy monitoring
- pirate_weather - Weather forecasts
- bubble-card - UI improvements

**Key Configuration:**
- Hilo rate plan: flex d
- Challenge automation: Lower heat pump to 18°C during Hilo challenges
- Eufy: Requires secondary account with device sharing
- Enable configWritable for HACS and UI modifications
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 constellation.home-assistant module created following existing patterns
- [x] #2 services.home-assistant enabled with declarative configuration
- [x] #3 tuya_local and alarmo from nixpkgs customComponents
- [x] #4 HACS installed and functional for remaining integrations
- [ ] #5 Hilo integration installed with flex d rate plan
- [ ] #6 Sinope/Neviweb130 integration installed for WiFi thermostats
- [ ] #7 Eufy Security integration installed with secondary account
- [ ] #8 Powercalc and Pirate Weather installed via HACS
- [x] #9 Hilo challenge automation defined declaratively
- [x] #10 Container-based homeassistant removed from services/home.nix
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Infrastructure complete: NixOS module created, HA deployed on storage, HACS installed, Hilo challenge automation in place. Remaining tasks (159.3-159.7) require manual UI configuration - see each task for detailed steps.
<!-- SECTION:NOTES:END -->
