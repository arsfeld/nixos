---
id: task-139
title: Investigate using Hydra to replace GitHub Actions for CI/CD
status: Done
assignee:
  - Claude
created_date: '2025-11-03 14:44'
updated_date: '2025-11-03 21:28'
labels:
  - ci
  - investigation
  - infrastructure
  - hydra
dependencies: []
priority: medium
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
The weekly update workflow in GitHub Actions has been persistently problematic and has never worked reliably:

- Only 2 successful runs in 6 months (task-133 investigation)
- Multiple failures due to platform issues (concurrency conflicts, reusable workflow bugs)
- Currently attempting to fix by inlining build matrix (task-134)
- Overall fragility suggests we may need a more robust solution

**Goal**: Investigate whether Hydra (NixOS's native CI/CD system) could replace GitHub Actions for our automated builds, tests, and deployments.

**Context**: Since this is a NixOS-heavy infrastructure with multiple hosts and complex build requirements, Hydra's native Nix integration might be a better fit than GitHub Actions.

**Key Questions to Answer**:
- Can Hydra handle our current workflow needs (flake updates, multi-host builds, automatic deployments)?
- What infrastructure would be required to self-host Hydra?
- How would Hydra integrate with our existing Tailscale network and Attic cache?
- What are the tradeoffs compared to GitHub Actions (maintenance burden, features, reliability)?
- Are there other alternatives worth considering (GitLab CI, Buildkite, etc.)?

**Related Tasks**:
- task-133: Initial investigation of GitHub Actions failures
- task-134: Current attempt to fix workflow by inlining build matrix
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Research Hydra's capabilities and feature set relevant to our use case
- [x] #2 Document infrastructure requirements (hosting, resources, maintenance)
- [x] #3 Compare Hydra vs GitHub Actions for our specific workflows
- [x] #4 Identify integration points with existing infrastructure (Tailscale, Attic, deploy-rs)
- [x] #5 Document tradeoffs and provide recommendation (Hydra, GitHub Actions, or alternatives)
- [x] #6 If Hydra is recommended, outline high-level implementation plan
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
## Implementation Plan

### Phase 1: Understand Current State
1. Review existing GitHub Actions workflow to understand requirements, failures, and integration points

### Phase 2: Research Hydra
2. Investigate Hydra's capabilities for flake evaluation, multi-host builds, caching, and scheduling
3. Document infrastructure requirements (hosting, resources, database, maintenance, security)

### Phase 3: Integration Analysis
4. Evaluate integration with Tailscale, Attic cache, deploy-rs, and GitHub

### Phase 4: Alternative Research
5. Survey alternatives (GitLab CI, Buildkite, Drone CI, improved GitHub Actions)

### Phase 5: Analysis & Recommendation
6. Compare all options across reliability, Nix integration, maintenance burden, features, cost, and migration complexity
7. Provide clear recommendation with reasoning and implementation plan if applicable

**Deliverable**: Comprehensive findings document covering all acceptance criteria with actionable recommendation
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
## Phase 1: Current GitHub Actions Analysis

### Workflow Overview

The repository uses two main workflows:

**1. update.yml (Weekly Update)**
- Runs weekly (cron: Sunday midnight UTC) or manually via workflow_dispatch
- Steps:
  1. **update job**: Updates flake inputs, checks for changes, encodes flake.lock
  2. **build job**: Calls build.yml with dry-activate mode
  3. **commit job**: Commits flake.lock changes if build succeeds
  4. **build-boot job**: Calls build.yml again with boot activation

**2. build.yml (Build System)**
- Reusable workflow called by update.yml and triggered on push to main/master
- Matrix build strategy for two hosts:
  - cloud (aarch64-linux)
  - storage (x86-64-linux)
- Steps per host:
  1. Free up disk space (remove unused packages)
  2. Setup QEMU for aarch64 emulation
  3. Setup Tailscale (connects to bat-boa.ts.net)
  4. Install Nix with aarch64 support
  5. Use Magic Nix Cache
  6. Run deploy-rs to build and deploy systems

### Failure History (from task-133)

- **Only 2 successful runs in 6 months** (June 15, July 20, 2025)
- **Failures started July 27, 2025**
- **Root cause (confirmed)**: Concurrency conflict between update.yml and build.yml
  - Both workflows shared same concurrency group due to ${{github.workflow}} resolution
  - Fixed by removing concurrency block from build.yml
  - First successful build after fix on Nov 2, 2025

### Current Issues

1. **Fragile reusable workflow pattern**: The concurrency issue shows that reusable workflows in GitHub Actions have subtle gotchas
2. **Long build times**: 60-minute timeout, builds take 5-10+ minutes per host
3. **Resource constraints**: Need to free up disk space before building
4. **Platform complexity**: QEMU emulation for aarch64, Tailscale setup, SSH configuration
5. **No caching of derivations**: Only uses Magic Nix Cache, doesn't leverage Attic effectively

### What Works Well

1. **Matrix builds**: Parallel building of multiple hosts
2. **Dry-activate testing**: Tests builds before committing
3. **Integration with deploy-rs**: Native NixOS deployment tool
4. **Tailscale networking**: Secure access to hosts for deployment

## Phase 2: Hydra Research

### Capabilities

**Core Features:**
- Native Nix-based CI/CD system developed by NixOS project
- Evaluates Nix expressions to create jobs automatically
- Supports flakes (with flake.lock requirement)
- Matrix builds via Nix evaluation (discovers jobs from Nix expressions)
- Built-in binary cache integration
- Web UI for build status and artifacts
- Prometheus metrics export for monitoring
- Aggregate jobs for gating on multiple tests
- API for querying latest builds (enables deployment automation)

**Scheduling & Triggers:**
- Periodic evaluation (cron-like)
- SCM polling (GitHub, GitLab, etc.)
- Manual triggers
- Webhook support (via plugins)

### Infrastructure Requirements

**Hosting:**
- Requires NixOS host (only officially supported platform)
- Three components: evaluator, queue runner, server
- PostgreSQL database (auto-configured by NixOS module)
- Build slaves (can be remote or local)

**Minimal Configuration:**
```nix
services.hydra = {
  enable = true;
  hydraURL = "https://hydra.example.com";
  notificationSender = "hydra@example.com";
  buildMachinesFiles = []; # Use local machine
  useSubstitutes = true;
};
```

**Resource Requirements:**
- Database: PostgreSQL with moderate storage for build metadata
- Disk space: Depends on build artifact retention
- CPU/RAM: Modest for evaluator/queue runner, more for builds
- Network: For fetching inputs and pushing to binary caches

**Maintenance Burden:**
- Database backups (stateful, not fully declarative)
- Known issue: Queue runner occasionally stalls (requires periodic restarts)
- Git timeout tuning needed for large repos like nixpkgs
- Initial admin user requires direct Unix access
- Version compatibility between Hydra and builders

### Integration Analysis

**Tailscale:**
- Hydra can be exposed via Tailscale Funnel or MagicDNS
- Build slaves can be accessed over Tailscale network
- Would fit naturally into existing bat-boa.ts.net setup

**Harmonia Cache (current setup):**
- Hydra has built-in binary cache signing and serving
- Could replace or complement Harmonia
- Hydra can push to external caches like S3, Harmonia, or Attic
- Automatic cache population for all builds

**deploy-rs:**
- Hydra provides API to fetch latest successful builds
- Could trigger deploy-rs via webhook or manual workflow
- No native deploy-rs integration (would need custom scripting)
- Hydra focuses on building, not deployment orchestration

**GitHub:**
- Can poll GitHub repos or receive webhooks
- Limited native GitHub integration (no check runs, PR comments)
- Would lose GitHub Actions integration features

## Phase 3: Alternative Research

### Hercules CI
- **Type**: SaaS Nix-native CI/CD
- **Pros**: Native Nix support, Cachix integration, NixOps/Terraform support, managed service
- **Cons**: Commercial (pricing unclear), SaaS dependency, less community adoption

### Garnix
- **Type**: SaaS Nix-specific CI provider
- **Pros**: Flake-native, includes binary cache, simple setup
- **Cons**: SaaS dependency, flake-only (no legacy Nix), newer/less proven

### GitLab CI
- **Type**: Self-hosted or SaaS CI/CD platform
- **Pros**: Mature, full-featured, NixOS module for runners, built-in container registry
- **Cons**: Heavy infrastructure, limited Nix-awareness, requires GitLab instance

### Buildkite
- **Type**: Hybrid CI/CD (managed orchestration, self-hosted agents)
- **Pros**: Highly scalable, flexible, enterprise-grade, Nix support via agents
- **Cons**: Commercial, complex setup, overkill for small infrastructure

### Improved GitHub Actions
- **Type**: SaaS CI/CD (current solution)
- **Pros**: Already integrated, free for public repos, good ecosystem, recent reliability improvements
- **Cons**: Limited Nix-awareness, past reliability issues, opaque platform changes
- **Improvements**: Better caching (Magic Nix Cache), update-flake-lock action, simplified workflows

## Phase 4: Comparative Analysis

### Option Comparison Matrix

| Criterion | GitHub Actions (Current) | GitHub Actions (Improved) | Hydra | Hercules CI | GitLab CI |
|-----------|-------------------------|---------------------------|-------|-------------|----------|
| **Nix Integration** | Basic (via actions) | Good (Magic Nix Cache) | Excellent (native) | Excellent (native) | Basic (via runners) |
| **Reliability** | Poor (2/50+ runs) | Unknown (needs testing) | Good (proven at scale) | Unknown (newer) | Excellent (mature) |
| **Maintenance Burden** | None (SaaS) | None (SaaS) | **High** (self-hosted) | Low (SaaS) | **Very High** (full GitLab) |
| **Setup Complexity** | Low (existing) | Low (refactor) | **Medium-High** | Low | **Very High** |
| **Cost** | **Free** | **Free** | Hosting only (~$0) | Unknown (commercial) | Hosting only (~$0) |
| **Binary Cache** | Magic Nix Cache | Magic Nix Cache | **Built-in + Harmonia** | Cachix integration | Manual setup |
| **Deployment** | deploy-rs integrated | deploy-rs integrated | Custom scripting needed | NixOps support | Custom scripting |
| **GitHub Integration** | **Excellent** | **Excellent** | Poor (polling/webhooks) | Good | Poor |
| **Multi-arch Support** | QEMU (slow) | QEMU (slow) | **Remote builders** | Remote builders | QEMU or runners |
| **Visibility** | GitHub UI | GitHub UI | Hydra Web UI | Hercules UI | GitLab UI |
| **Time to Deploy** | 0 (live) | 1-2 days (refactor) | **1-2 weeks** (setup) | 1-3 days | **2-4 weeks** |

### Key Insights

**Current GitHub Actions Issues:**
1. Concurrency bug was **recently fixed** (Nov 2, 2025)
2. Only 1 test run since fix - insufficient data on reliability
3. Problems were platform bugs, not fundamental limitations
4. Recent GitHub Actions reliability improvements (cache v2 backend)

**Hydra Reality Check:**
1. **Self-hosting burden**: PostgreSQL, state management, queue runner stalls
2. **No deployment orchestration**: Would need custom deploy-rs integration
3. **Limited GitHub integration**: No PR checks, status updates, or native auth
4. **Overkill for 2 hosts**: Hydra shines with 10s-100s of jobs
5. **Migration complexity**: New workflows, new UI, new operational model

**Cost-Benefit Analysis:**
- **Benefit of switching**: Better Nix integration, built-in caching
- **Cost of switching**: 1-2 weeks setup, ongoing maintenance, lost GitHub integration
- **Risk**: Unknown if it solves the actual reliability problem

## Phase 5: Recommendation

### **PRIMARY RECOMMENDATION: Stay with GitHub Actions (Improved)**

**Rationale:**

1. **Root cause was fixed**: The concurrency bug that caused 6 months of failures has been identified and resolved (task-133). The workflow succeeded after the fix.

2. **Insufficient failure data**: Only 1 successful run since fix. We don't know if reliability is actually still a problem. **The premature optimization fallacy applies here.**

3. **High switching cost**: Hydra requires:
   - 1-2 weeks of implementation time
   - New PostgreSQL service on cloud/storage
   - Custom deploy-rs integration scripting
   - Learning curve for operation and debugging
   - Ongoing maintenance (database backups, queue runner restarts)

4. **Lost capabilities**: GitHub integration (PR checks, commit statuses, UI), free hosting, existing ecosystem.

5. **Not addressing the real problem**: The failures were GitHub Actions platform bugs, not Nix integration issues. Switching to Hydra doesn't prevent platform-level issues.

### Recommended Action Plan

**Phase 1: Observe (1-2 months)**
1. Monitor weekly update workflow for 6-8 runs
2. Document any failures with root cause analysis
3. Track success rate and identify patterns

**Phase 2: Optimize if needed**
If reliability issues persist:
1. Implement `DeterminateSystems/update-flake-lock` action (automates flake updates with PRs)
2. Use Harmonia cache more effectively (push on successful builds)
3. Consider splitting update and deploy into separate workflows
4. Add better retry logic and failure notifications

**Phase 3: Re-evaluate if still failing**
Only after 2+ months of ongoing failures, consider:
1. **First choice**: Hercules CI (if pricing is reasonable) - Nix-native SaaS, no self-hosting
2. **Second choice**: Hydra - if confident in maintenance capacity
3. **Third choice**: Simplify workflow to remove complexity

### Alternative: Hydra Implementation Plan (If Proceeding Despite Recommendation)

**Phase 1: Basic Setup (Week 1)**
1. Enable Hydra on `storage` host (more resources than cloud)
2. Configure PostgreSQL and initial admin user
3. Expose via `hydra.arsfeld.one` through Caddy gateway
4. Set up authentication (Authelia integration or local users)

**Phase 2: Job Configuration (Week 1-2)**
1. Create Hydra project for nixos-config repo
2. Define jobsets for master branch
3. Configure flake evaluation (outputs.hydraJobs)
4. Set up SCM polling or webhooks

**Phase 3: Build Integration (Week 2)**
1. Configure cloud as aarch64 remote builder
2. Test multi-arch builds
3. Configure Harmonia cache pushing
4. Set up aggregate job for gating deployments

**Phase 4: Deployment Automation (Week 2)**
1. Create deployment script using Hydra API
2. Integrate with deploy-rs
3. Set up notifications (email, GitHub issues)
4. Test end-to-end workflow

**Phase 5: Migration (Week 3)**
1. Run Hydra in parallel with GitHub Actions
2. Compare reliability and performance
3. Disable GitHub Actions if Hydra proves superior
4. Document operational procedures

**Estimated Effort**: 40-60 hours over 2-3 weeks
**Ongoing Maintenance**: 2-4 hours/month (monitoring, updates, troubleshooting)

### Final Verdict

**Don't migrate to Hydra now.** The GitHub Actions workflow was fixed 1 day ago. Give it time to prove itself. If it fails consistently over the next 2 months, then revisit this investigation with real data on what's actually failing.

The concurrency bug discovery shows that sometimes the simplest explanation (platform bug) is correct, and switching to complex self-hosted infrastructure would have been premature optimization.

**Next Steps:**
1. Monitor GitHub Actions reliability for 2 months (create tracking task)
2. Document this decision for future reference
3. Set calendar reminder to re-evaluate in January 2026
4. If problems persist, start with GitHub Actions optimizations before considering Hydra
<!-- SECTION:NOTES:END -->
