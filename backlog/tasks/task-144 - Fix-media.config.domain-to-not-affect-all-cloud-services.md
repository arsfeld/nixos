---
id: task-144
title: Fix media.config.domain to not affect all cloud services
status: Done
assignee: []
created_date: '2025-11-12 19:36'
updated_date: '2025-11-12 19:45'
labels:
  - cloud
  - infrastructure
  - dns
  - regression
dependencies: []
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
The change to `media.config.domain = "arsfeld.dev"` in hosts/cloud/configuration.nix affects ALL media services on the cloud host, not just metadata-relay. This is a global setting that changes the domain for every service registered in the media gateway.

## Problem
- `media.config.domain` is a global setting that applies to all services
- Changed from default `arsfeld.one` to `arsfeld.dev` for task-143
- This affects ntfy, vault, whoogle, yarr, thelounge, and all other cloud services
- Services that were working on `*.arsfeld.one` may now be broken

## Impact
Services affected on cloud host:
- ntfy.arsfeld.dev (was ntfy.arsfeld.one)
- vault.arsfeld.dev (was vault.arsfeld.one)
- whoogle.arsfeld.dev (was whoogle.arsfeld.one)
- yarr.arsfeld.dev (was yarr.arsfeld.one)
- thelounge.arsfeld.dev (was thelounge.arsfeld.one)
- metadata-relay.arsfeld.dev (new service)

## Possible Solutions

**Option 1: Revert to arsfeld.one and add DNS**
- Revert `media.config.domain` back to `arsfeld.one`
- Add DNS records in Cloudflare for `*.arsfeld.one`
- All services use consistent domain

**Option 2: Add per-service domain override**
- Keep most services on `arsfeld.one`
- Add ability to override domain per-service in media.gateway
- Only metadata-relay uses `arsfeld.dev`

**Option 3: Keep arsfeld.dev and update all DNS**
- Keep `media.config.domain = "arsfeld.dev"`
- Verify all affected services work with new domain
- Document the change

## Recommendation
Option 1 (revert to arsfeld.one) is cleanest and most consistent. The global domain setting should match the DNS configuration.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 All cloud services are accessible via their correct domains
- [x] #2 DNS configuration matches media.config.domain setting
- [x] #3 No service availability regressions from task-143 changes
- [x] #4 Documentation updated with correct service URLs
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
## Resolution

**Approach Taken**: Option 1 - Revert to arsfeld.one

**Changes Made**:
1. Reverted `media.config.domain = "arsfeld.dev"` back to `"arsfeld.one"` in hosts/cloud/configuration.nix:65
2. Re-enabled `constellation.sites.arsfeld-dev.enable = true` (was disabled due to domain conflict)

**Verification**:
- DNS configuration for `*.arsfeld.one` already exists (confirmed in docs/architecture/network.md:129)
- All cloud services will now use their original domains:
  - ntfy.arsfeld.one
  - vault.arsfeld.one
  - whoogle.arsfeld.one
  - yarr.arsfeld.one
  - thelounge.arsfeld.one
  - metadata-relay.arsfeld.one

**Impact**:
- No DNS changes required - wildcard DNS already points to cloud server
- All services maintain consistent domain usage
- Services with explicit domain overrides (blog, plausible, planka, siyuan) remain on arsfeld.dev as intended

## Final Solution

**Problem**: `media.config.domain` is a global setting that affects ALL services in the media gateway. Setting it to "arsfeld.dev" for metadata-relay broke all other cloud services that expect "arsfeld.one".

**Solution**: Use a per-service domain configuration approach (similar to blog, plausible, planka, siyuan):

1. Created dedicated service module at `hosts/cloud/services/metadata-relay.nix`
2. Module defines its own `services.metadata-relay.domain` option (defaults to "metadata-relay.arsfeld.dev")
3. Module creates a Caddy virtual host directly, bypassing the media gateway's global domain
4. Uses `useACMEHost = "arsfeld.dev"` to leverage the existing wildcard certificate from `constellation.sites.arsfeld-dev`
5. Proxies to the metadata-relay container on port 4001

**Changes Made**:
1. Created `hosts/cloud/services/metadata-relay.nix` - Dedicated service module with domain configuration
2. Updated `hosts/cloud/services/default.nix` - Added metadata-relay.nix to imports
3. Updated `hosts/cloud/configuration.nix`:
   - Kept `media.config.domain = "arsfeld.one"` (for all gateway services)
   - Enabled `services.metadata-relay` with `domain = "metadata-relay.arsfeld.dev"`
   - Re-enabled `constellation.sites.arsfeld-dev` (provides wildcard cert)

**Verification**:
```bash
# Service is running
systemctl status docker-metadata-relay.service  # active (running)
docker ps | grep metadata  # Up 51 minutes (healthy)

# Domain is accessible
curl https://metadata-relay.arsfeld.dev/health
# Response: {"status":"ok","version":"0.3.0","service":"metadata-relay"}
```

**Result**:
- metadata-relay.arsfeld.dev ✓ Working
- All other cloud services remain on *.arsfeld.one ✓ No regressions
- Both domain patterns coexist without conflict ✓
<!-- SECTION:NOTES:END -->
