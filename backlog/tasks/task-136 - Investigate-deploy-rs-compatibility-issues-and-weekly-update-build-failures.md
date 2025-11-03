---
id: task-136
title: Investigate deploy-rs compatibility issues and weekly update build failures
status: To Do
assignee: []
created_date: '2025-11-02 20:43'
labels:
  - infrastructure
  - ci
  - deploy-rs
  - investigation
dependencies: []
priority: medium
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
The weekly flake update is causing storage builds to fail due to deploy-rs compatibility issues. The problem appears to be:

1. The eh5 flake dependency updated to use XYenon's deploy-rs fork (PR #346) which attempts to fix Nix 2.32+ compatibility
2. This fork causes build failures with: `error: path '/nix/store/.../linux-6.17.5-modules-shrunk/lib' is not in the Nix store`
3. However, deploy-rs itself may be fundamentally broken or incompatible with the current setup

## Background

- Local builds succeed with the same configuration
- The issue only manifests in CI (GitHub Actions)
- The XYenon fork (github.com/XYenon/deploy-rs, branch fix/nix-2-32) is an unmerged PR attempting to fix Nix 2.32+ compatibility
- Our system uses Nix 2.32.1 (Determinate Nix 3.12.0)

## Investigation Needed

1. Determine if deploy-rs is the right tool for this use case
2. Evaluate alternatives:
   - Switch to Colmena (already configured in flake)
   - Use plain nix-rebuild
   - Evaluate nixops4 or other tools
3. If keeping deploy-rs:
   - Wait for PR #346 to be merged
   - Find the actual root cause of the build failure
   - Determine if it's a deploy-rs bug, Nix version incompatibility, or configuration issue
4. Review whether the weekly update should build with deploy-rs at all, or just do `nix build`

## Related

- task-135: Initial investigation of the build failure
- task-133: Weekly update workflow implementation
- Workflow run 19014479081: Failed storage build
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Determined whether to continue using deploy-rs or switch to an alternative
- [ ] #2 If keeping deploy-rs: identified root cause and implemented a fix
- [ ] #3 If switching: migrated CI workflows and deployment processes to new tool
- [ ] #4 Weekly update workflow builds succeed for both cloud and storage hosts
<!-- AC:END -->
