---
id: task-133
title: Investigate failing weekly update GitHub workflow
status: Done
assignee: []
created_date: '2025-11-02 13:23'
updated_date: '2025-11-02 16:04'
labels:
  - github
  - ci
  - investigation
dependencies: []
priority: medium
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
The weekly update task in GitHub Actions is failing. Need to investigate the root cause and determine what's breaking in the workflow.

This likely involves:
- Reviewing GitHub Actions workflow logs
- Checking the workflow configuration file
- Understanding what the weekly update task is supposed to do (dependencies, flake updates, etc.)
- Identifying the specific failure point
- Determining if it's a temporary issue or requires code changes
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Identified the specific failure in the GitHub Actions logs
- [x] #2 Understood what the weekly update workflow is supposed to accomplish
- [x] #3 Determined the root cause of the failure
- [x] #4 Documented findings (either as task notes or in a follow-up fix task)
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
## Investigation Findings

### Observed Behavior
- Weekly update workflow has been failing consistently since July 27, 2025
- Only 2 successful runs in the past 6 months (June 15, July 20)
- All recent failures show the same pattern:
  - `update` job: ✅ succeeds
  - `build` job: ❌ never runs (missing from job list)
  - `commit` and `build-boot` jobs: skipped (because build never ran)

### Root Cause Analysis

The build job is defined as a reusable workflow call:
```yaml
build:
  needs: update
  if: needs.update.outputs.has_changes == 'true'
  uses: ./.github/workflows/build.yml
  permissions:
    contents: read
    actions: read
  with:
    flake_lock: ${{ needs.update.outputs.flake_lock }}
    activation_mode: "dry-activate"
  secrets: inherit
```

The build job is not being triggered even though:
1. The update job succeeds
2. The update job sets `has_changes=true` in its output
3. The flake.lock is successfully encoded and stored

### Potential Issues

1. **GitHub Actions Bug**: There may be an issue with how GitHub Actions evaluates the conditional `if: needs.update.outputs.has_changes == 'true'` when calling reusable workflows

2. **Permissions Conflict**: The permissions block was added in commit 63fee7e (Aug 16, after last success). GitHub Actions may not allow specifying permissions when calling reusable workflows with `secrets: inherit`

3. **Output Format Issue**: The output might not be in the expected format (though logs show it's being set correctly)

### Comparison with Successful Run

Successful run (July 20, 2025) showed these jobs:
- update - success
- build / Build cloud - success
- build / Build storage - success
- commit - success
- build-boot / Build cloud - success
- build-boot / Build storage - success

The build job created nested jobs when it worked correctly.

## Proposed Fix

Removed the `permissions` block from both reusable workflow calls (`build` and `build-boot` jobs). 

According to GitHub Actions documentation, when calling a reusable workflow, permissions should be defined within the called workflow itself, not at the caller level. The permissions block at the caller level can prevent the workflow from being triggered properly.

The fix removes these blocks:
```yaml
permissions:
  contents: read
  actions: read
```

From both the `build` and `build-boot` jobs in update.yml.

The build.yml workflow already has appropriate permissions defined for its jobs, so this change should allow the reusable workflow to be called properly.

## Critical Discovery

After extensive testing, the root cause has been identified:

**The reusable workflow call (`uses: ./.github/workflows/build.yml`) is not being invoked at all.**

This occurs even when:
- The condition `if: needs.update.outputs.has_changes == 'true'` is removed entirely
- Top-level permissions are added
- The build.yml workflow has proper `workflow_call:` trigger defined
- The flake.lock inputs are correctly passed

### Evidence

Multiple test runs show the same pattern:
- update job: ✅ completes successfully
- build job: ❌ completely missing from jobs list (not even shown as "skipped")
- commit job: skipped (because build never runs)
- build-boot job: skipped (because commit never runs)

The successful run from July 20, 2025 showed the build job should create nested jobs:
- build / Build cloud
- build / Build storage

But current runs don't create the build job at all.

### Possible Root Causes

1. **GitHub Actions Platform Issue**: There may be a bug or limitation in how GitHub Actions handles reusable workflows with top-level permissions and `secrets: inherit`

2. **Configuration Conflict**: The combination of:
   - Top-level `permissions:` block
   - Reusable workflow with `secrets: inherit`
   - Job-level `permissions:` in the called workflow
   
   May be causing GitHub Actions to silently fail to invoke the workflow.

3. **Workflow Caching Issue**: GitHub Actions might be caching an invalid workflow state

### Next Steps

Since the reusable workflow approach is fundamentally broken, there are several possible solutions:

1. **Inline the build logic**: Move the build matrix directly into update.yml instead of using a reusable workflow
2. **Use workflow_dispatch trigger**: Have update workflow trigger build workflow via `gh workflow run`
3. **Simplify workflow**: Remove the intermediate build step and have update directly build and commit
4. **Report to GitHub**: This appears to be a GitHub Actions bug that should be reported

## Recommendation

The quickest fix is to **inline the build matrix** directly into the update.yml workflow, eliminating the need for the reusable workflow call that's causing the issue.

## Final Resolution

### Actual Root Cause (Confirmed)

Commit b747afd (July 26, 2025) added a concurrency block to build.yml:

```yaml
concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true
```

When update.yml calls build.yml as a reusable workflow, `${{ github.workflow }}` in the **called** workflow resolves to the **caller's** workflow name ("Weekly Update"). This means both workflows shared the same concurrency group, causing them to cancel each other with `cancel-in-progress: true`.

This explains why:
- The update job succeeded (it started first)
- The build job never appeared (it was immediately canceled)
- This started happening right after commit b747afd

### Solution Implemented

Commits f0786cb and b9a2300:
1. Removed the concurrency block from build.yml (reusable workflows should let callers control concurrency)
2. Kept the concurrency block in update.yml (the caller workflow)
3. Restored job-level permissions to reusable workflow calls (these were mistakenly removed during investigation)

### Verification

Workflow run 19014479081 confirmed the fix works:
- ✅ update job: success (5m2s)
- ✅ build / Build cloud: success (7m49s) - **FIRST TIME since July 20!**
- ❌ build / Build storage: failure (build error, unrelated to concurrency issue)
- ⏭️ commit: skipped (due to storage build failure)
- ⏭️ build-boot: skipped (due to commit skip)

**Key Success**: Build jobs now execute instead of being canceled by the concurrency conflict.

Note: The storage build failure is a separate issue (likely a legitimate build error) and not related to the concurrency problem that was preventing builds from running at all.
<!-- SECTION:NOTES:END -->
