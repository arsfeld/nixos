---
id: task-159.3
title: Configure Tuya Local integration for heat pump
status: To Do
assignee: []
created_date: '2025-12-15 03:10'
updated_date: '2025-12-15 04:12'
labels:
  - home-assistant
  - hacs
  - tuya
dependencies: []
parent_task_id: task-159
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Configure the Tuya Local integration (already included via nixpkgs customComponents) to control the heat pump.

**Note:** tuya_local is installed declaratively via the constellation module. This task is for UI configuration only.

**Steps:**
1. Open Home Assistant UI at hass.arsfeld.one
2. Go to Settings → Devices & Services → Add Integration
3. Search for "Tuya Local" and add it
4. Log in with Tuya/SmartLife app credentials
5. Select heat pump device for local control
6. Verify heat pump appears as a climate entity

**Benefits of local control:**
- No cloud dependency after initial setup
- Faster response times
- Works during internet outages
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Tuya Local integration configured via Home Assistant UI
- [ ] #2 Heat pump discovered and added as climate entity
- [ ] #3 Heat pump temperature can be controlled from Home Assistant
- [ ] #4 Local control verified (no cloud latency)
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Tuya Local is already installed via nixpkgs customComponents. Configuration requires UI steps at https://hass.arsfeld.one: Settings → Devices & Services → Add Integration → Tuya Local → Follow setup wizard with Tuya/SmartLife credentials.
<!-- SECTION:NOTES:END -->
