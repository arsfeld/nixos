---
id: task-159.4
title: Install Hilo integration via HACS
status: To Do
assignee: []
created_date: '2025-12-15 03:10'
updated_date: '2025-12-15 04:12'
labels:
  - home-assistant
  - hacs
  - hilo
dependencies: []
parent_task_id: task-159
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Install and configure the Hilo integration via HACS for Hydro-Québec challenge participation.

**Note:** Hilo is NOT in nixpkgs and must be installed via HACS.

**Repository:** https://github.com/dvd-dev/hilo (209 stars)

**Steps:**
1. Open Home Assistant UI
2. Go to HACS → Integrations → Explore & Download Repositories
3. Search for "Hilo" and install
4. Restart Home Assistant (Settings → System → Restart)
5. Add integration via Settings → Devices & Services
6. Authenticate with Hilo account
7. Configure:
   - Rate plan: **flex d**
   - Scan interval: 60s (minimum, don't go below 30s)
   - Challenge lock: Optional

This exposes `binary_sensor.hilo_challenge` and other sensors for automation.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Hilo integration installed via HACS
- [ ] #2 Hilo account authenticated
- [ ] #3 Rate plan set to flex d
- [ ] #4 binary_sensor.hilo_challenge entity available
- [ ] #5 Hilo devices discovered and added
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
HACS installed. To install Hilo: 1) Go to HACS → Integrations → Explore & Download 2) Search 'Hilo' and install 3) Restart HA 4) Settings → Devices & Services → Add Integration → Hilo 5) Configure with flex d rate plan.
<!-- SECTION:NOTES:END -->
