---
id: task-153.6
title: Deploy and test Brazil exit node on storage host
status: Done
assignee: []
created_date: '2025-11-30 19:31'
updated_date: '2025-11-30 20:46'
labels:
  - testing
  - deployment
dependencies:
  - task-153.2
  - task-153.5
parent_task_id: task-153
priority: medium
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Deploy the first exit node (Brazil) to the storage host and verify it works end-to-end.

## Deployment Steps

1. Generate AirVPN WireGuard config for Brazil
2. Store credentials in sops secrets
3. Enable module on storage host:
   ```nix
   constellation.vpnExitNodes = {
     enable = true;
     tailscaleAuthKeyFile = config.sops.secrets.tailscale-exit-key.path;
     nodes.brazil = {
       country = "Brazil";
       tailscaleHostname = "brazil-exit";
     };
   };
   ```
4. Deploy to storage: `just deploy storage`
5. Approve exit node in Tailscale admin console

## Testing Checklist

1. **Container health**
   - [ ] gluetun-brazil container running
   - [ ] tailscale-brazil container running
   - [ ] Containers restart on failure

2. **VPN connectivity**
   - [ ] Gluetun connected to AirVPN Brazil
   - [ ] Public IP shows Brazilian location
   - [ ] `curl http://localhost:8000/v1/publicip/ip` returns BR IP

3. **Tailscale integration**
   - [ ] Exit node visible in admin console
   - [ ] Hostname shows as "brazil-exit"
   - [ ] Can select as exit node from another device

4. **End-to-end test**
   - [ ] From laptop: `tailscale set --exit-node=brazil-exit`
   - [ ] Verify public IP is Brazilian
   - [ ] Internet connectivity works
   - [ ] `tailscale set --exit-node=` to disable
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Brazil exit node deployed to storage host
- [x] #2 Gluetun connects to AirVPN Brazil server
- [x] #3 Tailscale exit node appears in admin console
- [x] #4 Can use exit node from another Tailscale device
- [x] #5 Traffic routed through Brazilian IP verified
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Deployed to storage. Gluetun container running and connecting to Brazil (146.70.163.90). Manual test confirmed Brazilian IP (146.70.248.10, São Paulo). However, healthcheck intermittently failing due to DNS resolution timeouts during VPN reconnection. Tailscale container failing to start - needs investigation (may need to wait for gluetun healthcheck to pass first).

## Root Cause Found (2025-11-30)

The Tailscale container was failing with error:
```
Status: 400, Message: "requested tags [] are invalid or not permitted"
failed to auth tailscale: tailscale up failed: exit status 1
```

The existing `tailscale-key` secret does not have exit node capability pre-approved. A new Tailscale auth key is needed with:
- Reusable: Yes
- Pre-authorized: Yes  
- Exit node: Pre-approved

### Module fixes applied:
1. Added `--cap-add=NET_ADMIN` and `--device=/dev/net/tun` to Tailscale container (required for TUN device)
2. Moved `TS_AUTHKEY` to environment section

### Next step:
Generate new auth key with exit node capability and add as new secret.

## Successfully Completed (2025-11-30)

All issues resolved:
1. Created auth key via Tailscale API with `tag:exit` and exit node pre-approval
2. Added `--advertise-tags=tag:exit` to module
3. Created `tailscale-exit-key.age` secret

**Verification:**
- Exit node appears as `brazil-exit.bat-boa.ts.net` with "offers exit node"
- Public IP: 146.70.248.10 (São Paulo, Brazil)
- Gluetun healthy, Tailscale connected
<!-- SECTION:NOTES:END -->
