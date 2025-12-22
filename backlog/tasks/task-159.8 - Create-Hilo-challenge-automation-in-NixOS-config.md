---
id: task-159.8
title: Create Hilo challenge automation in NixOS config
status: Done
assignee: []
created_date: '2025-12-15 03:10'
updated_date: '2025-12-15 04:12'
labels:
  - home-assistant
  - automation
  - hilo
dependencies:
  - task-159.3
  - task-159.4
parent_task_id: task-159
priority: medium
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Add declarative automation to the constellation.home-assistant module for Hilo challenge response.

**Add to `modules/constellation/home-assistant.nix`:**

```nix
services.home-assistant.config = {
  "automation manual" = [
    {
      alias = "Hilo Challenge - Lower Heat Pump";
      description = "Lower Tuya heat pump to 18°C during Hilo challenges";
      trigger = [{
        platform = "state";
        entity_id = "binary_sensor.hilo_challenge";
        to = "on";
      }];
      action = [{
        service = "climate.set_temperature";
        target.entity_id = "climate.tuya_heat_pump";  # Adjust entity name
        data.temperature = 18;
      }];
      mode = "single";
    }
    {
      alias = "Hilo Challenge End - Restore Heat Pump";
      description = "Restore Tuya heat pump to 21°C after Hilo challenge";
      trigger = [{
        platform = "state";
        entity_id = "binary_sensor.hilo_challenge";
        from = "on";
        to = "off";
      }];
      action = [{
        service = "climate.set_temperature";
        target.entity_id = "climate.tuya_heat_pump";  # Adjust entity name
        data.temperature = 21;
      }];
      mode = "single";
    }
  ];
};
```

**Note:** Entity names need to be adjusted based on actual device names after Tuya and Hilo integrations are configured.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Hilo challenge start automation defined in NixOS config
- [x] #2 Hilo challenge end automation defined in NixOS config
- [ ] #3 Entity names updated to match actual devices
- [ ] #4 Automations appear in Home Assistant UI
- [ ] #5 Automation triggers correctly during test challenge
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
**Implementation Completed:**

Added the 'automation manual' section to `/home/arosenfeld/Code/nixos/modules/constellation/home-assistant.nix` with both Hilo challenge automations:

1. **Hilo Challenge - Lower Heat Pump**: Triggers when `binary_sensor.hilo_challenge` turns on, sets `climate.tuya_heat_pump` to 18°C
2. **Hilo Challenge End - Restore Heat Pump**: Triggers when `binary_sensor.hilo_challenge` turns off, restores `climate.tuya_heat_pump` to 21°C

**Entity Names:**
Using placeholder entity names with inline comments noting they need adjustment:
- `climate.tuya_heat_pump` - Adjust to match actual Tuya device entity
- `binary_sensor.hilo_challenge` - Will be created by Hilo integration

**Next Steps for Remaining Criteria:**

**Criteria #3 (Entity names):** After deploying and configuring Tuya/Hilo integrations in Home Assistant UI:
1. Navigate to Settings → Devices & Services
2. Find the Tuya heat pump device and note its entity_id (e.g., `climate.YOUR_DEVICE_NAME`)
3. Find the Hilo binary sensor and note its entity_id (e.g., `binary_sensor.hilo_challenge`)
4. Update lines 92 and 112 in `modules/constellation/home-assistant.nix` with actual entity IDs
5. Rebuild and redeploy: `just deploy storage`

**Criteria #4 (Automations in UI):** After deployment:
1. Access Home Assistant UI at https://home.arsfeld.one (or local IP:8123)
2. Navigate to Settings → Automations & Scenes
3. Verify both automations appear in the list (they'll be marked as 'automation manual')

**Criteria #5 (Test trigger):** After entity names are updated:
1. Wait for a real Hilo challenge event, OR
2. Manually trigger in Developer Tools → States by setting `binary_sensor.hilo_challenge` to 'on'
3. Verify heat pump temperature changes to 18°C
4. Set sensor back to 'off' and verify temperature restores to 21°C

**Configuration validated:** Nix build succeeds with no syntax errors.

Automation code added with placeholder entity names. Criteria #3-5 require deployment and Tuya/Hilo configuration to get actual entity IDs.

Automation code complete. Entity names (climate.tuya_heat_pump, binary_sensor.hilo_challenge) need to be updated in modules/constellation/home-assistant.nix after Tuya and Hilo integrations are configured to get actual entity IDs.
<!-- SECTION:NOTES:END -->
