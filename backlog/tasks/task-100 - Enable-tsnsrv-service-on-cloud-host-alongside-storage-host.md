---
id: task-100
title: Enable tsnsrv service on cloud host alongside storage host
status: Done
assignee:
  - assistant
created_date: '2025-10-28 19:12'
updated_date: '2025-10-28 20:21'
labels:
  - cloud
  - tsnsrv
  - tailscale
  - configuration
  - needs-competent-engineer
dependencies: []
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Enable tsnsrv service on cloud host to run alongside the existing tsnsrv on storage host.

## Goal
Have tsnsrv running on BOTH cloud and storage hosts, not just storage.

## Current State
- tsnsrv is enabled and running on storage host (hosts/storage/services/misc.nix:17)
- tsnsrv is disabled on cloud host (hosts/cloud/services.nix:25)
- Cloud host has the tsnsrv configuration block but enable = false

## What Needs to Happen
1. Set `services.tsnsrv.enable = true` in hosts/cloud/services.nix
2. Handle any build errors that occur from enabling it
3. If there are no services to expose via tsnsrv on cloud, configure it to handle that gracefully
4. Ensure tsnsrv service starts and runs successfully on cloud host
5. Verify both cloud and storage hosts have tsnsrv running simultaneously

## Previous Attempt Issues
- Build failed with "builtins.head called on an empty list" error
- Error occurred because no services with exposeViaTailscale run on cloud host
- Need to either configure tsnsrv to handle empty service list OR add services to expose on cloud

## Success Criteria
- tsnsrv service is enabled in hosts/cloud/services.nix
- Cloud host builds successfully
- tsnsrv-all.service is running on cloud host
- tsnsrv-all.service remains running on storage host
- Both services are healthy and operational
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Set services.tsnsrv.enable = true in hosts/cloud/services.nix
- [x] #2 Resolve any build errors that occur
- [x] #3 Deploy successfully to cloud host
- [x] #4 Verify tsnsrv-all.service is running on cloud host with systemctl status
- [x] #5 Verify tsnsrv-all.service still running on storage host
- [x] #6 Confirm both hosts have healthy tsnsrv services simultaneously
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
## Implementation Approach

### Root Cause
The tsnsrv NixOS module (line 638) tries to get the first service from the service list to determine which package to use:
```nix
firstService = lib.head (lib.attrValues config.services.tsnsrv.services);
```
This fails when the service list is empty, which happens on cloud host because no cloud services are in the `tailscaleExposed` list.

### Solution
Add commonly accessed cloud services to the `tailscaleExposed` list in `modules/constellation/services.nix`:
- ntfy - Notification service
- yarr - RSS reader  
- vault - Secrets management
- whoogle - Privacy-focused search
- thelounge - IRC web client

These services already run on cloud and are in the `funnels` list, so exposing them via Tailscale makes architectural sense.

### Changes
1. Update `modules/constellation/services.nix` - Add cloud services to tailscaleExposed list and update comment
2. Keep `hosts/cloud/services.nix` - tsnsrv already enabled
3. Build, test, and deploy to cloud host
4. Verify tsnsrv runs on both cloud and storage hosts
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
## Deployment Results

**Cloud host tsnsrv services:**
- yarr (http://127.0.0.1:7070)
- ntfy (http://127.0.0.1:1784)
- vault (http://127.0.0.1:8000)
- whoogle (http://127.0.0.1:5000)
- thelounge (http://127.0.0.1:9552)

**Storage host:** tsnsrv-all.service active and healthy

**Additional work:** Added thelounge service definition to constellation/services.nix including service port, bypassAuth, funnels, and tailscaleExposed lists.
<!-- SECTION:NOTES:END -->
