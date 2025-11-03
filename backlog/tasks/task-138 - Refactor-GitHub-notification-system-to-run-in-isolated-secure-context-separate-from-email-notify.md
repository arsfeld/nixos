---
id: task-138
title: >-
  Refactor GitHub notification system to run in isolated secure context separate
  from email-notify
status: Done
assignee: []
created_date: '2025-11-03 14:40'
updated_date: '2025-11-03 14:55'
labels:
  - security
  - refactoring
  - github
  - systemd
  - notifications
dependencies: []
priority: medium
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
The current implementation of GitHub issue creation for systemd failures has security and architectural issues:

**Current Problems:**
1. **Security**: The email@ service runs with HOME=/root, giving all service failure handlers access to root's home directory and configuration
2. **Poor separation of concerns**: GitHub issue creation is tightly coupled with email notifications in systemd-email-notify.nix
3. **Unnecessary complexity**: LLM analysis is duplicated/shared between email and GitHub notifications
4. **Privilege issues**: gh CLI authentication runs in the same context as email sending

**Proposed Architecture:**
Create a separate `github-issue@` systemd service that:
- Runs in an isolated context with minimal privileges
- Has its own dedicated user (e.g., `github-notifier`) with limited permissions
- Has gh CLI authentication configured only for that user (not root)
- Receives failure information via systemd (similar to email@)
- No HOME=/root exposure
- No LLM integration (remove LLM from GitHub issue creation entirely)

**Implementation Plan:**
1. Create new `modules/constellation/github-issue-notify.nix` module
2. Create dedicated system user for GitHub notifications
3. Set up gh CLI authentication for that user only (not root)
4. Create `github-issue@` systemd service template
5. Configure services to trigger both `email@` and `github-issue@` on failure (via onFailure)
6. Remove GitHub issue creation code from systemd-email-notify.nix
7. Remove LLM integration from GitHub issue creation (keep it only in email if desired)
8. Update constellation.githubNotify to use new isolated service

**Security Benefits:**
- No root HOME exposure
- Dedicated user with minimal permissions (only needs gh CLI access)
- Clear separation between email and GitHub notification systems
- Each system can be enabled/disabled independently
- Easier to audit and secure

**Current Workaround:**
Task-137 added HOME=/root to email@ service to make gh work, but this is a temporary fix that should be replaced with proper isolation.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 GitHub issue creation runs in isolated service context with dedicated user
- [x] #2 No HOME=/root or root privilege exposure in notification services
- [x] #3 LLM integration removed from GitHub issue creation
- [x] #4 Email and GitHub notifications are completely independent systems
- [x] #5 gh CLI authentication configured only for dedicated github-notifier user
- [x] #6 All existing GitHub notification functionality still works
<!-- AC:END -->
