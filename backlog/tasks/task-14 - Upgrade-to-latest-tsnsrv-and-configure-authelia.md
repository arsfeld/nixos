---
id: task-14
title: Upgrade to latest tsnsrv and configure authelia
status: Done
assignee: []
created_date: '2025-10-15 18:57'
updated_date: '2025-10-15 19:04'
labels:
  - infrastructure
  - authentication
  - tailscale
dependencies: []
priority: medium
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Upgrade to the latest version of tsnsrv from https://github.com/arsfeld/tsnsrv and properly configure authelia for authentication.

This involves:
- Reviewing the latest tsnsrv changes and features
- Updating the tsnsrv package/module in the NixOS configuration
- Setting up authelia integration with tsnsrv
- Configuring authentication flows and policies
- Testing the setup with Tailscale integration
<!-- SECTION:DESCRIPTION:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
## Implementation Summary

### Changes Made

1. **Updated tsnsrv flake input** from 2025-06-02 to 2025-10-15 (latest version)
   - New features include forward authentication, multi-service mode, and authBypassForTailnet

2. **Fixed Authelia integration path** in `modules/media/__utils.nix`
   - Changed authPath from `/api/verify` to `/api/authz/forward-auth` (correct Authelia endpoint)
   - Updated authCopyHeaders format to use empty string values for proper header copying
   - Enabled `authBypassForTailnet = true` to skip auth for Tailscale-authenticated users

3. **Resolved configuration conflict** in `modules/media/containers.nix`
   - Added `mkDefault` to container settings to allow constellation.services to override
   - Fixed priority conflict between media.containers and constellation.services modules

### Features Now Available

- **Forward Authentication**: All media gateway services (except those in bypassAuth list) now use Authelia for authentication
- **Tailscale User Bypass**: Users authenticated via Tailscale can bypass Authelia (useful for internal access)
- **Multi-Service Mode**: tsnsrv now runs all services in a single process (tsnsrv-all.service)
- **Header Copying**: User identity headers (Remote-User, Remote-Groups, Remote-Name, Remote-Email) are properly forwarded

### Testing

- Both storage and cloud configurations build successfully
- Code formatted with alejandra
- Ready for deployment

### Next Steps

To deploy and test:
```bash
just deploy storage
just deploy cloud
```

Verify that services requiring auth properly redirect to Authelia, and that Tailscale-authenticated users can access services directly.
<!-- SECTION:NOTES:END -->
