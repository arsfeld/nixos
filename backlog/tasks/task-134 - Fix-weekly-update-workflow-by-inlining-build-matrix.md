---
id: task-134
title: Fix weekly update workflow by inlining build matrix
status: In Progress
assignee: []
created_date: '2025-11-02 13:48'
updated_date: '2025-11-02 14:21'
labels:
  - github
  - ci
  - bug-fix
dependencies: []
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
The weekly update GitHub workflow is failing because the reusable workflow call to build.yml is not being invoked. Investigation revealed that:

1. **Failures started July 27, 2025** - but NO code changes to update.yml around that time
2. **Job-level permissions added Aug 16** - AFTER failures started, so not the root cause  
3. **Devenv migration Aug 12** - AFTER failures started
4. **The build job doesn't appear at all** - not skipped, completely missing from runs

**Root Cause Hypothesis**: Either a GitHub Actions platform change around July 20-27, 2025, or a repository settings change that affects reusable workflow calls with `secrets: inherit`.

**Alternative Solutions to Investigate (in order of preference)**:

1. **Remove BOTH top-level AND job-level permissions** - Revert to the exact working state from July 20
2. **Try explicit secrets** - Replace `secrets: inherit` with explicit secret passing
3. **Check repository Actions settings** - Verify workflow permissions and access policies
4. **Simplify workflow chain** - Remove the reusable workflow call (last resort)

**Files to modify**:
- `.github/workflows/update.yml` - Test removing all my investigation commits

**Related**:
- Fixes issue identified in task-133
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Build matrix is inlined in update.yml
- [ ] #2 Reusable workflow call is removed
- [ ] #3 Manual test run completes successfully with build job executing
- [ ] #4 Flake.lock updates are committed automatically
- [ ] #5 Test commits from investigation are reverted
<!-- AC:END -->
