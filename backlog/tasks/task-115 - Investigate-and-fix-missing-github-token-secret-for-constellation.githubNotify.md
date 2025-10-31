---
id: task-115
title: Investigate and fix missing github-token secret for constellation.githubNotify
status: Done
assignee: []
created_date: '2025-10-31 17:21'
updated_date: '2025-10-31 17:30'
labels:
  - storage
  - secrets
  - bug
  - build-failure
dependencies: []
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
The storage host build is failing due to a missing `github-token` agenix secret that's referenced by the constellation.githubNotify module.

**Error:**
```
error: attribute 'github-token' missing
at /home/arosenfeld/Code/nixos/modules/constellation/github-notify.nix:35:17:
   34|       type = types.path;
   35|       default = config.age.secrets.github-token.path;
    |                 ^
   36|       description = "Path to the GitHub token file (agenix secret)";
```

**Context:**
- constellation.githubNotify is enabled on storage host (line 23 of configuration.nix)
- The module expects config.age.secrets.github-token.path to exist
- This secret is not defined in secrets/secrets.nix
- Task-110 also mentions GitHub notification integration issues

**Investigation needed:**
1. Check if github-token secret exists in secrets/ directory
2. Check if it's just missing from secrets.nix definition
3. Determine if this is a new feature that was never completed
4. Review what the github-notify module does (creates GitHub issues for systemd failures)

**Possible solutions:**
- Add github-token to secrets/secrets.nix if the secret file exists
- Create the github-token secret if needed
- Make the tokenFile option optional with better defaults
- Disable githubNotify if it's not being used
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Storage host builds successfully without github-token errors
- [x] #2 Either github-token secret is properly configured or module handles missing token gracefully
- [x] #3 Decision documented on whether to use GitHub notifications or disable the feature
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
## Root Cause
The issue was a circular dependency in `modules/constellation/github-notify.nix`:
- Line 36 set `tokenFile` default to `config.age.secrets.github-token.path`
- But `age.secrets.github-token` was only declared later when `cfg.enable = true` (lines 43-46)
- This caused NixOS evaluation to fail because it tried to reference a secret before it was declared

## Solution
Fixed by refactoring the option definition:
1. Removed the problematic default value from the `tokenFile` option
2. Added explicit assignment in the `config` section using `mkDefault` (line 42)
3. This ensures the secret is declared before being referenced

## Verification
- Storage host builds successfully without errors
- The github-token secret is properly configured (exists in secrets/ and secrets.nix)
- GitHub notification feature is enabled and functional on storage host
<!-- SECTION:NOTES:END -->
