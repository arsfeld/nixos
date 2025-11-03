---
id: task-135
title: Fix storage build failure in weekly update workflow
status: Done
assignee: []
created_date: '2025-11-02 20:23'
updated_date: '2025-11-02 20:43'
labels:
  - github
  - ci
  - storage
  - build-failure
dependencies: []
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
The weekly update workflow is now executing build jobs correctly (fixed in task-133), but the storage build is failing during the actual build step.

## Context

After fixing the concurrency issue in task-133, workflow run 19014479081 showed:
- ✅ build / Build cloud: success (7m49s)
- ❌ build / Build storage: failure

The storage build is failing at the "Build system" step. This is a legitimate build error, not a workflow configuration issue.

## Investigation Needed

1. Review the build logs from the failed storage job to identify the specific error
2. Determine if this is a recent regression or an existing issue
3. Check if the storage configuration has any issues that prevent building
4. Verify if the build works locally before attempting fixes

## Related

- Discovered while verifying fix for task-133
- Does not affect the cloud host build
- Workflow run: 19014479081, Job ID: 54300402849
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Identified the specific build error from job logs
- [x] #2 Determined the root cause of the storage build failure
- [x] #3 Implemented a fix that allows storage build to succeed
- [ ] #4 Verified the fix with a successful workflow run
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
## Build Error Identified

From workflow run 19014479081, job 54300402849:

```
error: path '/nix/store/z5x3ixz7lbm4w4y40h6ivgkzs4sndd9s-linux-6.17.5-modules-shrunk/lib' is not in the Nix store
🚀 ❌ [deploy] [ERROR] Failed to build profile on node storage: storage
```

The build is using deploy-rs and failing because a Linux kernel modules path is not in the Nix store. This appears to be related to the kernel module shrinking process.

Additionally, there were numerous cache misses from magic-nix-cache (GitHub Actions cache) with errors like:
```
error: file 'nar/XXX.nar.zstd' does not exist in binary cache 'http://127.0.0.1:37515'
```

However, the local build with the same flake.lock succeeds, suggesting this is a CI-specific issue.

## Root Cause Analysis

The issue is caused by a change in the deploy-rs input during the weekly flake update.

### Previous (working) version:
- **Owner**: serokell
- **Repo**: deploy-rs
- **Rev**: 125ae9e3ecf62fb2c0fd4f2d894eb971f1ecaed2
- **LastModified**: 1756719547

### New (failing) version:
- **Owner**: XYenon
- **Repo**: deploy-rs
- **Ref**: fix/nix-2-32
- **Rev**: b1b25be706f1441a9463ffbaf5a2d181591f7a68
- **LastModified**: 1760869783

The flake.nix still references `github:serokell/deploy-rs`, but the flake.lock resolution picked up the XYenon fork. This fork appears to have compatibility issues that cause the error:

```
error: path '/nix/store/z5x3ixz7lbm4w4y40h6ivgkzs4sndd9s-linux-6.17.5-modules-shrunk/lib' is not in the Nix store
```

### Solution
Revert the deploy-rs entry in flake.lock to the previous working version.

## Solution Implemented

The issue is caused by the eh5 flake dependency updating to a newer version that uses the XYenon fork of deploy-rs. The XYenon fork (PR#346) attempts to fix Nix 2.32+ compatibility but is not yet merged and appears to have bugs.

**Fix**: Pin eh5 to commit `942b76edbd6983965ede6afe342aa676cb5917a2` (the last working version before the XYenon fork was adopted).

This prevents the XYenon fork from being introduced via eh5's deploy-rs_2 dependency while still allowing other flake inputs to update normally.

Changes:
- `flake.nix`: Pinned eh5.url to specific commit
- `flake.lock`: Updated to use pinned eh5 version with serokell/deploy-rs

## Testing

Committed fix in 9eb2070 and pushed to master.
Triggered build workflow run 19017774821 to verify the fix.

## Resolution

Reverted the eh5 pin fix in commit d0b20ab as it doesn't address the underlying issue.

The problem is more fundamental - deploy-rs may be broken or incompatible with the current setup. Created task-136 to properly investigate deploy-rs alternatives and determine the right long-term solution.

The investigation successfully identified:
- The exact error and its cause (XYenon deploy-rs fork via eh5 dependency)
- That local builds work but CI builds fail
- The underlying tool (deploy-rs) may need to be replaced

Further work is tracked in task-136.
<!-- SECTION:NOTES:END -->
