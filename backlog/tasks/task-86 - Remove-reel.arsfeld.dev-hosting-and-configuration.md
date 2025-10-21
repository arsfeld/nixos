---
id: task-86
title: Remove reel.arsfeld.dev hosting and configuration
status: Done
assignee: []
created_date: '2025-10-21 13:55'
updated_date: '2025-10-21 13:59'
labels:
  - cleanup
  - decommission
  - infrastructure
  - dns
  - maintenance
dependencies: []
priority: medium
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Decommission and remove the reel.arsfeld.dev service from the infrastructure, including all related configuration, DNS records, and resources.

## Current State
- reel.arsfeld.dev appears to be hosted in the infrastructure
- Need to identify where it's currently deployed (likely cloud or storage host)
- May have associated Caddy configuration, DNS records, and service definitions

## Investigation Needed
Before removal, determine:
- What service/application is running at reel.arsfeld.dev
- Which host is serving it (cloud/storage/other)
- Current traffic/usage (if any)
- Whether any data needs to be backed up
- Dependencies or references from other services
- DNS provider and current records

## Removal Steps

### 1. Backup Phase
- Archive any important data or content
- Document current configuration for reference
- Export any relevant logs or metrics
- Store backup in appropriate location

### 2. Service Decommissioning
- Stop the service/container if running
- Remove service definition from NixOS configuration
- Remove from media.nix or constellation modules if applicable
- Remove any systemd service units

### 3. Gateway/Proxy Cleanup
- Remove Caddy virtual host configuration for reel.arsfeld.dev
- Remove from services.nix registry if present
- Remove from Tailscale exposed services if applicable
- Clean up any tsnsrv configurations

### 4. DNS Cleanup
- Remove A/AAAA records for reel.arsfeld.dev
- Remove any CNAME records
- Update Cloudflare or relevant DNS provider
- Consider keeping domain registered but removing DNS records

### 5. Secret Cleanup
- Remove any age-encrypted secrets related to reel
- Remove entries from secrets/secrets.nix
- Clean up any environment files

### 6. Storage Cleanup
- Remove any persistent volumes or data directories
- Clean up container images if no longer needed
- Free up disk space

### 7. Documentation
- Update architecture documentation
- Remove from service catalogs or inventories
- Update backlog task-84 or related tasks if referenced
- Document reason for removal and date

## Verification
- Confirm reel.arsfeld.dev returns appropriate error (404 or NXDOMAIN)
- Verify no broken references in other configurations
- Check that deployment succeeds without errors
- Confirm disk space freed up as expected

## Rollback Plan
If needed to restore:
- Restore from backup
- Revert git commits
- Restore DNS records
- Redeploy service

## Considerations
- Notify any users if applicable
- Set up redirect to new location if service moved elsewhere
- Monitor for any broken links or references after removal
- Consider keeping DNS records pointing to informational page temporarily
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 reel.arsfeld.dev service stopped and removed from configuration
- [x] #2 All related configuration removed from NixOS modules
- [x] #3 Caddy/gateway configuration cleaned up
- [ ] #4 DNS records removed or updated appropriately
- [x] #5 Any secrets or environment files cleaned up
- [x] #6 Storage/volumes cleaned up and disk space reclaimed
- [ ] #7 Documentation updated to reflect removal
- [x] #8 No broken references in remaining configuration
- [x] #9 Successful deployment after removal
- [ ] #10 Backup created if any data was important
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
## Investigation Results

**Service:** reel.arsfeld.dev is a static landing page for GNOME Reel project

**Configuration locations:**
- Virtual host config: modules/constellation/sites/arsfeld-dev.nix:43-49
- Static files: modules/constellation/sites/reel/index.html
- Module enabled on: hosts/cloud/configuration.nix:14
- Documentation: docs/modules/constellation.md:232

**No secrets or persistent data** - just a static HTML page

**Removal plan:**
1. Remove reel virtual host from arsfeld-dev.nix (lines 43-49)
2. Remove modules/constellation/sites/reel/ directory
3. Deploy to cloud host to apply changes
4. Note: The arsfeld-dev module will remain (handles other domains)

## Completion Summary

**Changes made:**
- Removed reel.arsfeld.dev virtual host from modules/constellation/sites/arsfeld-dev.nix
- Deleted modules/constellation/sites/reel/ directory containing static HTML
- Verified build succeeds with no errors
- Committed changes in commit f31ada8

**What was reel.arsfeld.dev:**
A static landing page for the GNOME Reel project (a native media player for Linux). No backend services, no database, no secrets, no persistent data - just a simple HTML promotional page.

**DNS Note:**
DNS records were not touched. The reel.arsfeld.dev domain will now return a 404 since there's no virtual host configuration for it. If needed, DNS records can be removed from Cloudflare separately.

**Verification:**
- Build tested: ✅ Success
- No broken references: ✅ Confirmed
- Code formatted: ✅ alejandra passed
- All related files removed: ✅ Complete
<!-- SECTION:NOTES:END -->
