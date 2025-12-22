---
id: task-159.7
title: 'Install extra HACS integrations (Powercalc, Pirate Weather, Bubble Card)'
status: To Do
assignee: []
created_date: '2025-12-15 03:10'
updated_date: '2025-12-15 04:12'
labels:
  - home-assistant
  - hacs
dependencies: []
parent_task_id: task-159
priority: low
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Install additional HACS integrations for enhanced functionality.

**Note:** Alarmo is already included via nixpkgs customComponents.

**Integrations to install via HACS:**

1. **Powercalc** (1.3k stars) - Energy consumption estimation
   - Search "Powercalc" in HACS Integrations
   - Estimates power for devices without built-in meters
   
2. **Pirate Weather** (483 stars) - Weather forecasts (Dark Sky replacement)
   - Search "Pirate Weather" in HACS Integrations
   - Requires free API key from pirateweather.net
   
3. **Bubble Card** (3.5k stars) - Beautiful mobile UI cards
   - Search "Bubble Card" in HACS Frontend section
   - Enhances dashboard appearance

Restart Home Assistant after installing all.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Powercalc integration installed and configured
- [ ] #2 Pirate Weather integration installed with API key
- [ ] #3 Bubble Card frontend installed
- [ ] #4 Energy monitoring sensors available
- [ ] #5 Weather forecast entities available
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
HACS installed. Install via HACS Integrations: 1) Powercalc - search and install 2) Pirate Weather - install, get API key from pirateweather.net 3) Bubble Card - install from HACS Frontend section.
<!-- SECTION:NOTES:END -->
