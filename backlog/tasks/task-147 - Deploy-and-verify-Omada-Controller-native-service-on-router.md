---
id: task-147
title: Deploy and verify Omada Controller native service on router
status: To Do
assignee: []
created_date: '2025-11-13 17:30'
updated_date: '2025-11-13 19:30'
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

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
## Deployment Abandoned - Alternative Approach

After multiple deployment attempts and troubleshooting, the native NixOS service deployment encountered persistent issues with jsvc daemon and Java VM configuration:

**Issues Encountered:**
1. Root permission check in control.sh (fixed)
2. Bash function syntax errors (fixed)
3. OMADA_HOME path resolution (fixed)
4. OMADA_USER configuration (fixed)
5. **jsvc 'Cannot find any VM in Java Home' error (unresolved)**

The jsvc issue proved complex and requires deep understanding of:
- jsvc's specific JVM directory structure requirements
- How NixOS JDK packaging differs from traditional Linux layouts
- Potential need for custom wrappers or symlinks

**Decision:**
Given the complexity and time investment (65+ minute rebuilds, multiple debugging cycles), we're pursuing an alternative approach: deploying the Docker-based Omada Controller on the storage host instead.

See new task for Docker-based deployment on storage host.

**Native Package Status:**
The native package (task-146) successfully builds and most functionality works. The remaining jsvc issue could be resolved with more research into jsvc+NixOS integration, but the Docker approach is more pragmatic for now.
<!-- SECTION:NOTES:END -->
