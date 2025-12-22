---
id: task-159.5
title: Install Sinope/Neviweb130 integration via HACS
status: To Do
assignee: []
created_date: '2025-12-15 03:10'
updated_date: '2025-12-15 04:12'
labels:
  - home-assistant
  - hacs
  - sinope
dependencies: []
parent_task_id: task-159
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Install and configure the Sinope/Neviweb130 integration via HACS for WiFi thermostats.

**Note:** neviweb130 is NOT in nixpkgs and must be installed via HACS.

**Repository:** https://github.com/claudegel/sinope-130 (101 stars)

**Steps:**
1. Open Home Assistant UI
2. Go to HACS → Integrations → Custom repositories
3. Add repository: `claudegel/sinope-130` (Category: Integration)
4. Install "Neviweb130" integration
5. Restart Home Assistant
6. Add to configuration via Settings → Devices & Services
7. Enter Neviweb cloud credentials

**Note:** WiFi thermostats work WITHOUT a gateway - just needs Neviweb cloud account.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Neviweb130 integration installed via HACS
- [ ] #2 Neviweb account authenticated
- [ ] #3 WiFi thermostats discovered and controllable
- [ ] #4 Climate entities available for each thermostat
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
HACS installed. To install Neviweb130: 1) Go to HACS → Integrations → Custom repositories 2) Add 'claudegel/sinope-130' (Category: Integration) 3) Install Neviweb130 4) Restart HA 5) Settings → Devices & Services → Add with Neviweb credentials.
<!-- SECTION:NOTES:END -->
