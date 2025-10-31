---
id: task-112
title: Remove cache-all-hosts system after atticd removal
status: Done
assignee: []
created_date: '2025-10-31 16:01'
updated_date: '2025-10-31 16:05'
labels:
  - storage
  - cleanup
  - systemd
dependencies: []
priority: medium
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
The cache-all-hosts timer is failing because it depends on atticd.service which was recently disabled. Since attic is no longer in use, remove all cache-all-hosts infrastructure including the timer, service, and any related scripts/commands.

**Context:**
- Recent commit "fix(storage): disable attic..." removed atticd
- cache-all-hosts.timer now fails with: "Unit atticd.service not found"
- System is using GitHub Actions Magic Nix Cache instead

**Components to remove:**
- cache-all-hosts.timer (systemd timer)
- cache-all-hosts.service (systemd service)
- Any shell scripts/commands for cache-all-hosts
- Any configuration files referencing cache-all-hosts

**Search locations:**
- `modules/constellation/` - likely in services or common modules
- Check for any references in host configurations
- Look for shell script definitions
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 cache-all-hosts.timer no longer appears in systemctl --failed
- [ ] #2 No references to cache-all-hosts remain in the codebase
- [ ] #3 System rebuilds successfully without errors
- [ ] #4 Deploy to storage host completes successfully
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
## Implementation Completed

Removed the entire cache.nix file instead of just the timer/service, since all Attic infrastructure is now unused.

### Changes Made:
1. **Deleted** `hosts/storage/cache.nix` (entire file - 237 lines)
   - atticd service configuration
   - cache-push, cache-all-hosts, deploy-cached scripts
   - systemd service and timer for cache-all-hosts
   - GC roots and deployment preservation logic
2. **Removed** cache.nix import from `hosts/storage/configuration.nix`
3. **Removed** Attic Binary Cache section from `CLAUDE.md`
   - Setup instructions
   - Usage examples
   - Cache scripts documentation
4. **Removed** from `justfile`:
   - `cache` command
   - `deploy-cached` command
   - `attic push` from `build` command

### Verification:
- Code formatted successfully with alejandra
- No remaining references to cache-all-hosts, cache-push, or deploy-cached in codebase (except historical task files)
- Committed in bfc15c5

### Note:
The storage host build currently fails due to an unrelated pre-existing issue with missing github-token secret in constellation.githubNotify module. This is not caused by the cache.nix removal.
<!-- SECTION:NOTES:END -->
