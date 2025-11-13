---
id: task-148
title: Deploy Omada Controller Docker container on storage host
status: To Do
assignee: []
created_date: '2025-11-13 19:30'
labels:
  - deployment
  - docker
  - storage
  - omada-controller
  - alternative-approach
dependencies: []
priority: medium
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Deploy TP-Link Omada Controller using the Docker image from https://github.com/mbentley/docker-omada-controller on the storage host instead of using the native NixOS package on the router.

**Rationale:**
The native NixOS packaging approach (tasks 146-147) encountered significant complexity with jsvc daemon requirements and Java VM configuration. The Docker-based approach is more mature, well-tested, and easier to maintain.

**Benefits of Storage Host Deployment:**
- More powerful hardware (storage vs router)
- Existing container infrastructure with Podman
- Docker image is actively maintained and widely used
- Avoid complex native packaging issues
- Can still manage router network devices remotely

**Implementation:**
1. Configure Omada Controller container on storage host using constellation.media or constellation.services
2. Expose web interface (ports 8088/8043)
3. Configure firewall rules for device discovery (UDP 27001, 29810-29817)
4. Set up persistent data volume
5. Configure network connectivity to router for device management
6. Add to gateway/Caddy for external access if needed

**Docker Image:**
- Repository: https://github.com/mbentley/docker-omada-controller
- Well-maintained with regular updates
- Supports multiple Omada Controller versions
- Includes MongoDB and all dependencies

**Network Considerations:**
- Omada Controller can manage devices on remote networks
- May need to configure device adoption for remote controller
- Consider VPN or secure tunnel between storage and router network if needed
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Omada Controller running in Docker container on storage host
- [ ] #2 Web interface accessible at https://omada.arsfeld.one or similar
- [ ] #3 Can discover and adopt network devices on router network
- [ ] #4 Data persists across container restarts
- [ ] #5 Integrated with constellation services framework
- [ ] #6 Firewall rules configured for device communication
- [ ] #7 Documentation updated with access info
<!-- AC:END -->
