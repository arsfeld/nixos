---
id: task-159.6
title: Install Eufy Security integration via HACS
status: To Do
assignee: []
created_date: '2025-12-15 03:10'
updated_date: '2025-12-15 04:12'
labels:
  - home-assistant
  - hacs
  - eufy
dependencies: []
parent_task_id: task-159
priority: medium
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Install and configure the Eufy Security integration via HACS for cameras and doorbells.

**Note:** eufy_security is NOT in nixpkgs and must be installed via HACS.

**Repository:** https://github.com/fuatakgun/eufy_security (1.2k stars)

**Important:** Eufy forces logout of other sessions when add-on starts.

**Setup steps:**
1. Create a **secondary Eufy account** (don't use main account)
2. In main Eufy app, share home/devices with secondary account (include admin rights)
3. Open Home Assistant HACS → Integrations → Custom repositories
4. Add repository: `fuatakgun/eufy_security` (Category: Integration)
5. Install the integration
6. Restart Home Assistant
7. Add integration using secondary account credentials

**Recommended:** Also install WebRTC integration from HACS for better camera streaming.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Secondary Eufy account created
- [ ] #2 Devices shared with secondary account
- [ ] #3 Eufy Security integration installed via HACS
- [ ] #4 Cameras and doorbells discovered
- [ ] #5 Camera streams accessible in Home Assistant
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
HACS installed. To install Eufy Security: 1) Create secondary Eufy account 2) Share devices from main account 3) HACS → Custom repos → add 'fuatakgun/eufy_security' 4) Install and restart 5) Configure with secondary account credentials.
<!-- SECTION:NOTES:END -->
