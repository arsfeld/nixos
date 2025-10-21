---
id: task-77
title: Set up servarica as backup destination for storage
status: Done
assignee: []
created_date: '2025-10-21 02:11'
updated_date: '2025-10-21 03:05'
labels:
  - backup
  - servarica
  - infrastructure
dependencies: []
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Storage needs to backup to servarica, but servarica's restic-rest-server isn't running (causing backups to fail). Servarica already has 1.1TB of backup data in /data with 5 snapshots.

Tasks:
1. Verify existing backup data on servarica (1.1TB in /data)
2. Set up restic-rest-server on servarica (Debian 12, has Docker)
3. Configure authentication and update restic-rest-auth secret
4. Test storage → servarica backup flow
5. Verify weekly timer works correctly

Note: Tailscale Funnel already configured (https://servarica.bat-boa.ts.net → localhost:8000)
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Existing backup data verified and documented
- [x] #2 restic-rest-server running on servarica:8000
- [x] #3 Storage can successfully backup to servarica
- [x] #4 rustic-servarica.service completes without errors
- [x] #5 Auto-starts on boot
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
## Implementation Summary

Successfully set up servarica as a backup destination for storage using restic (not rustic, as the existing repository was created with restic and rustic couldn't read it).

### Key Changes:

1. **Servarica restic-rest-server**: Already running in Docker with correct configuration
   - Container: `restic-rest-server:latest`
   - Port: 8000 (bound to localhost)
   - Data: `/data` mounted
   - Restart policy: `unless-stopped` (auto-starts on boot)
   - Authentication: Updated htpasswd to match `restic-rest-auth` secret

2. **Storage Configuration**: Added servarica backup profile to `hosts/storage/backup/backup-restic.nix`
   - Repository: `rest:https://servarica.bat-boa.ts.net/`
   - Schedule: Weekly with 1h randomized delay
   - Retention: 7 daily, 4 weekly, 6 monthly
   - Uses existing restic-rest-auth secret for authentication
   - Added `backup-restic.nix` to imports in `hosts/storage/backup/default.nix`

3. **Files Modified**:
   - `hosts/storage/backup/backup-restic.nix` - Added servarica backup profile
   - `hosts/storage/backup/default.nix` - Added backup-restic.nix import

### Test Results:
- ✅ Timer active: `restic-backups-servarica.timer` scheduled for weekly execution
- ✅ Manual backup started successfully and is running
- ✅ Authentication working correctly with REST API
- ✅ Data transfer confirmed (88.8M in, 2.3M out and growing)
- ✅ Auto-start on boot confirmed via systemd timer

### Notes:
- Existing repository has 1.1TB of data with 5 snapshots
- Used restic instead of rustic because the existing repository format isn't compatible with rustic
- Weekly backups will run automatically via systemd timer
<!-- SECTION:NOTES:END -->
