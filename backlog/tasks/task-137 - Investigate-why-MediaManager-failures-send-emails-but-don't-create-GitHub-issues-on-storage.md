---
id: task-137
title: >-
  Investigate why MediaManager failures send emails but don't create GitHub
  issues on storage
status: Done
assignee: []
created_date: '2025-11-03 13:07'
updated_date: '2025-11-03 14:41'
labels:
  - bug
  - notifications
  - github
  - storage
  - mediamanager
dependencies: []
priority: medium
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
MediaManager service failures on the storage host are triggering email notifications successfully, but GitHub issues are not being created automatically. This appears to be a MediaManager-specific problem, as the GitHub notification integration was supposedly fixed in task-110.

**Current Behavior:**
- ✅ Email notifications are being sent when MediaManager fails
- ❌ GitHub issues are NOT being created for these failures
- ⚠️ This is specific to MediaManager on the storage host

**Expected Behavior:**
When MediaManager fails, the systemd-email-notify system should:
1. Send an email notification (working)
2. Include LLM analysis in the email
3. Create a GitHub issue in the nixos repository (NOT working)

**Context:**
- Host: storage
- Service: MediaManager (likely podman-mediamanager or similar systemd unit)
- Related: task-110 fixed GitHub notification integration generally
- Module: `modules/constellation/github-notify.nix`
- Script: `packages/send-email-event/create-github-issue.py`

**Investigation Areas:**
1. Check if constellation.githubNotify is enabled on storage host
2. Verify the MediaManager service name matches the notification trigger patterns
3. Review journal logs for MediaManager failures to see if GitHub creation is being attempted
4. Check if GitHub token has correct permissions
5. Look for any MediaManager-specific filtering or exclusions in the notification config
6. Verify configure-gh.service status on storage
7. Check for any errors in email@*.service logs related to MediaManager failures
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Root cause identified for why MediaManager failures don't create GitHub issues
- [ ] #2 GitHub issues are successfully created when MediaManager fails on storage host
- [ ] #3 Email notifications continue to work for MediaManager failures
- [ ] #4 Verify the fix doesn't break other service notifications
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
## Root Cause Analysis

The github-notify module was configuring GitHub issue creation correctly at the NixOS option level, but had two missing pieces:

### Issue 1: gh not in service PATH (FIXED)
The `gh` CLI binary was added to `environment.systemPackages` (system-wide) but NOT to the `email@` service's PATH. 

**Fix Applied**: Added `gh` to the email@ service PATH in github-notify.nix (commit 9289982)

### Issue 2: gh authentication not accessible (REQUIRES REFACTORING)
Even with gh in PATH, the email@ service cannot access gh authentication because:
- gh CLI stores auth at `/root/.config/gh/hosts.yml` (set up by configure-gh.service)
- The email@ service runs without HOME environment variable
- Setting HOME=/root would be a major security issue (gives all service failure handlers access to root's home)

**Attempted Fix (REVERTED)**: Tried setting HOME=/root in email@ service, but this creates security issues by exposing root's home directory to all service failure handlers.

**Proper Solution**: task-138 - Refactor GitHub notifications to run in an isolated `github-issue@` service with a dedicated user, completely separate from email notifications. This provides proper security isolation and removes the need for any root access.

## Current Status

**What Works:**
- ✅ Emails are sent for service failures
- ✅ LLM analysis is included in emails  
- ✅ gh CLI is in the service PATH

**What Doesn't Work:**
- ❌ GitHub issues are not created (gh authentication not accessible in service context)
- ❌ Architecture couples GitHub and email notifications insecurely

**Next Steps:**
Complete task-138 to properly implement GitHub issue creation with security isolation.

## Commits

- 9289982: fix(github-notify): add gh CLI to email@ service PATH for issue creation
- 904223b: fix(systemd-email-notify): set HOME for email@ service (REVERTED - security issue)
- Revert commit: Reverted HOME=/root change due to security concerns
<!-- SECTION:NOTES:END -->
