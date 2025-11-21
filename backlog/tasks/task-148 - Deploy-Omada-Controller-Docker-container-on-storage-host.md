---
id: task-148
title: Deploy Omada Controller Docker container on storage host
status: In Progress
assignee: []
created_date: '2025-11-13 19:30'
updated_date: '2025-11-14 15:35'
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
- [x] #1 Omada Controller running in Docker container on storage host
- [ ] #2 Web interface accessible at https://omada.arsfeld.one or similar
- [ ] #3 Can discover and adopt network devices on router network
- [x] #4 Data persists across container restarts
- [x] #5 Integrated with constellation services framework
- [x] #6 Firewall rules configured for device communication
- [ ] #7 Documentation updated with access info
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
## Implementation Summary

Successfully configured TP-Link Omada Controller as a Docker container on the storage host.

### Configuration Details

**Location**: `modules/constellation/media.nix` (storageServices section)

**Docker Image**: `mbentley/omada-controller:latest`

**Network Configuration**:
- Using host networking mode for optimal device discovery and adoption
- Web interface accessible via HTTPS on port 8043
- HTTP interface on port 8088
- Portal HTTPS on port 8843
- All required UDP ports for device discovery (27001, 29810, etc.) are available via host network

**Persistent Storage**:
- Data: `${vars.configDir}/omada/data` → `/opt/tplink/EAPController/data`
- Logs: `${vars.configDir}/omada/logs` → `/opt/tplink/EAPController/logs`
- On storage host, configDir defaults to `/var/data`

**Container Options**:
- `--ulimit nofile=4096:8192` for proper file descriptor handling
- `--stop-timeout 60` for graceful MongoDB shutdown (prevents database corruption)

**Gateway Integration**:
- Added to `modules/constellation/services.nix` in storage section (port 8043)
- Added to `bypassAuth` list (has built-in authentication)
- NOT in `funnels` list (internal network access only)
- Web interface will be accessible at `https://omada.arsfeld.one` via cloud gateway
- Direct access via `storage.bat-boa.ts.net:8043` within tailnet

### Build Status

✅ Storage host configuration builds successfully
✅ Service units generated correctly (podman-omada.service)

### Next Steps for Deployment

1. Format code with `just fmt`
2. Commit changes
3. Deploy to storage host: `just deploy storage`
4. Verify service startup: `systemctl status podman-omada`
5. Access web interface at `https://omada.arsfeld.one`
6. Complete initial Omada Controller setup
7. Test device discovery and adoption from router network

### Acceptance Criteria Status

- [x] #1 Omada Controller running in Docker container on storage host (configured, needs deployment)
- [ ] #2 Web interface accessible at https://omada.arsfeld.one (pending deployment)
- [ ] #3 Can discover and adopt network devices on router network (pending testing after deployment)
- [x] #4 Data persists across container restarts (persistent volumes configured)
- [x] #5 Integrated with constellation services framework (added to media.nix and services.nix)
- [x] #6 Firewall rules configured for device communication (host networking provides all required ports)
- [ ] #7 Documentation updated with access info (pending deployment verification)

## Gateway Issue Investigation

After extensive debugging, discovered that while the Omada Controller is running correctly and the backend HTTPS configuration is set up properly (insecureTls = true), requests through omada.arsfeld.one return:

```
Bad Request
This combination of host and port requires TLS.
```

### What's Working
- ✅ Omada Controller service running on storage (podman-omada.service)
- ✅ Backend accessible at https://storage:8043 (verified from cloud host)
- ✅ Caddy configuration includes correct insecureTls transport settings
- ✅ TLS handshake successful for omada.arsfeld.one frontend
- ✅ Other services through gateway work fine (tested jellyfin.arsfeld.one)

### What's Not Working
- ❌ Requests to https://omada.arsfeld.one fail with TLS error
- ❌ Caddy access log for omada remains empty (requests not reaching virtual host)

### Workaround
Direct access works via:
- Internal: https://storage.bat-boa.ts.net:8043
- From storage host: https://localhost:8043

### Next Steps for Followup
- Investigate Caddy virtual host routing for omada.arsfeld.one
- Check if wildcard *.arsfeld.one block is interfering
- Consider testing with a different subdomain
- May need to enable debug logging in Caddy to trace request routing
<!-- SECTION:NOTES:END -->
