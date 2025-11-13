---
id: task-147
title: Deploy and verify Omada Controller native service on router
status: To Do
assignee: []
created_date: '2025-11-13 17:30'
labels:
  - deployment
  - router
  - omada-controller
dependencies:
  - task-146
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Deploy the newly packaged native Omada Controller v6.0.0.24 to the router host and verify all functionality works correctly.

**Prerequisites:**
- task-146 completed (package and module created)
- Router configuration built successfully
- Current Omada Controller settings backed up

**Deployment Process:**
1. Export current configuration from Docker Omada Controller
2. Deploy new NixOS configuration to router
3. Verify systemd services start correctly
4. Test web interface accessibility
5. Verify device discovery and adoption
6. Import backup configuration if needed
7. Clean up old Docker container

**Success Criteria:**
- Services start without errors
- Web interface accessible at https://router.bat-boa.ts.net:8043
- MongoDB 6.0 running and accessible
- Device discovery working (UDP ports functional)
- Existing network devices can be managed

**Rollback Plan:**
If deployment fails, revert to previous Docker-based configuration by:
1. Re-enabling Docker container service
2. Restoring /var/data/omada data
3. Rebuilding and deploying previous configuration
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Native Omada Controller service deployed to router
- [ ] #2 systemctl status omada-controller shows active (running)
- [ ] #3 systemctl status mongodb shows active (running)
- [ ] #4 Web interface accessible at https://router.bat-boa.ts.net:8043
- [ ] #5 Initial setup wizard completes successfully
- [ ] #6 Device discovery ports listening (UDP 27001, 29810-29817)
- [ ] #7 Network devices can be adopted and managed
- [ ] #8 Configuration backup imported successfully (if applicable)
- [ ] #9 Old Docker container stopped and cleaned up
<!-- AC:END -->
