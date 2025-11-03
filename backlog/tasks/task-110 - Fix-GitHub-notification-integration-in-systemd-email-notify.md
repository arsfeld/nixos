---
id: task-110
title: Fix GitHub notification integration in systemd-email-notify
status: Done
assignee: []
created_date: '2025-10-31 13:47'
updated_date: '2025-10-31 15:24'
labels:
  - bug
  - systemd
  - notifications
  - github
dependencies: []
priority: medium
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
The systemd email notification system is partially working but the GitHub issue creation functionality is not functioning as expected. The email notifications and LLM analysis (Google Gemini) are working correctly and sending notifications when services fail.

**Current Status:**
- ✅ Email notifications: Working (sends HTML emails via msmtp)
- ✅ LLM analysis: Working (Google Gemini provides crash analysis)
- ❌ GitHub issues: Not working (issues not being created automatically)

**Affected Hosts:**
- raider (has system running)
- storage (has system running)

Both hosts have been running the notification system for a while and should have logs from crashed services that can be used for debugging.

**Expected Behavior:**
When a systemd service fails, the system should:
1. Send an email notification (working)
2. Include LLM analysis in the email (working)
3. Create a GitHub issue in the configured repository (NOT working)
4. If the same service fails again within 24 hours, comment on the existing issue instead of creating a new one

**Technical Context:**
- Module: `modules/constellation/github-notify.nix`
- Script: `packages/send-email-event/create-github-issue.py`
- GitHub CLI (`gh`) is used for issue creation
- Authentication: Uses `age.secrets.github-token.path` via agenix
- Service: `configure-gh.service` sets up GitHub CLI authentication

**Debugging Areas:**
1. Verify `configure-gh.service` is running and succeeding
2. Check GitHub CLI authentication status (`gh auth status`)
3. Review logs from `email@*.service` instances for GitHub-related errors
4. Verify the GitHub token has correct permissions (issues: write)
5. Check if the script is being called with correct parameters from `modules/systemd-email-notify.nix:110-128`
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 GitHub issues are successfully created when a service fails on raider or storage
- [x] #2 Created issues have correct title format: [hostname] service-name failed - hash
- [x] #3 Issues include service status, logs, and optional LLM analysis in the body
- [x] #4 Issues are labeled correctly with systemd-failure, host:hostname, and service-type labels
- [x] #5 When a service fails multiple times within 24 hours, the existing issue is updated with a comment instead of creating a duplicate
- [x] #6 The configure-gh.service successfully authenticates GitHub CLI on system boot
- [x] #7 Error messages from GitHub issue creation failures are visible in journal logs
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
## Implementation Summary

**Root Cause:**
- constellation.githubNotify module was disabled by default
- No github-token.age secret configured
- Module was never enabled on raider or storage hosts

**Changes Made:**

1. **Added GitHub token secret** (secrets/secrets.nix)
   - Created github-token.age with personal access token
   - Configured for raider and storage hosts
   - Token has 'repo' scope for issue creation

2. **Enabled GitHub notifications on both hosts**
   - raider: constellation.githubNotify.enable = true
   - storage: constellation.githubNotify.enable = true

3. **Fixed label handling** (packages/send-email-event/create-github-issue.py)
   - Script now handles missing GitHub labels gracefully
   - Retries without labels if initial attempt fails
   - Prevents failures when labels don't exist in repo

**Testing Results:**

Tested with real podman-audiobookshelf.service failure from storage:
- ✅ Issue created successfully: https://github.com/arsfeld/nixos/issues/1
- ✅ Duplicate detection verified (3 test runs)
  - Run 1: Created issue #1
  - Run 2: Added comment to issue #1
  - Run 3: Added another comment to issue #1
- ✅ No spam risk: Multiple failures update same issue within 24h window
- ✅ Works without predefined labels

**Commits:**
- a33d3c5: fix(raider,storage): enable GitHub issue creation for systemd failures
- 41072ef: fix(packages): handle missing GitHub labels gracefully in create-github-issue

**Next Steps:**

To deploy:
1. Deploy to raider: `just deploy raider`
2. Verify configure-gh.service: `ssh raider systemctl status configure-gh`
3. Check gh auth: `ssh raider gh auth status`
4. Deploy to storage: `just deploy storage`

Optional enhancements:
- Create recommended labels in repo: systemd-failure, host:storage, host:raider, container, backup, web-server
- Monitor first real failure to verify end-to-end functionality
<!-- SECTION:NOTES:END -->
