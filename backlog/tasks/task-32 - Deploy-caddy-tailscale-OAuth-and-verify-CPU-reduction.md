---
id: task-32
title: Deploy caddy-tailscale OAuth and verify CPU reduction
status: In Progress
assignee: []
created_date: '2025-10-16 13:39'
updated_date: '2025-10-16 13:42'
labels:
  - deployment
  - verification
  - caddy-tailscale
  - oauth
  - performance
dependencies:
  - task-30
  - task-31
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
## Overview

Deploy the completed caddy-tailscale with OAuth implementation to the storage host and verify the expected CPU usage reduction from 60.5% to ~2-5%.

## Context

**Tasks 30 & 31 are complete**:
- ✅ caddy-tailscale package with OAuth support built (task-30)
- ✅ Gateway module updated for OAuth (task-31)
- ✅ tsnsrv disabled (task-31)
- ✅ OAuth secrets configured (task-31)
- ✅ DRY configuration options added (task-31)
- ✅ Configuration builds successfully

**Current State**:
- Configuration is uncommitted but ready
- tsnsrv still running (will be disabled on deployment)
- 64 separate Tailscale nodes visible in admin console
- CPU usage: ~60.5%

**Expected State After Deployment**:
- Single "caddy" Tailscale node
- Node marked as ephemeral
- CPU usage: ~2-5% (55% reduction!)
- All 64 services accessible through single node

## Pre-Deployment Checklist

Before deploying, capture baseline metrics:

```bash
# 1. Count current Tailscale nodes
tailscale status | grep -c "storage-" || echo "Check Tailscale admin console"

# 2. Check current CPU usage
ssh storage "top -bn1 | grep Cpu"

# 3. List all tsnsrv processes
ssh storage "ps aux | grep tsnsrv | wc -l"

# 4. Verify uncommitted changes
git status
```

**Expected baseline**:
- ~64 nodes named "storage-{service}"
- CPU usage: ~60-65%
- Multiple tsnsrv processes running

## Deployment Steps

### 1. Commit Changes

```bash
git add -A
git commit -m "feat: migrate from tsnsrv to caddy-tailscale with OAuth

- Add caddy-tailscale package with OAuth support (vendored erikologic fork)
- Update gateway module to use OAuth client credentials
- Disable tsnsrv (64 nodes → 1 node)
- Add DRY configuration options for Tailscale
- Update secrets with OAuth credentials

Expected result: CPU usage reduction from 60.5% to ~2-5%

Closes: task-30, task-31
Related: task-29

🤖 Generated with [Claude Code](https://claude.com/claude-code)

Co-Authored-By: Claude <noreply@anthropic.com>"
```

### 2. Deploy to Storage

```bash
just deploy storage
```

**What happens during deployment**:
1. Nix builds new configuration with caddy-tailscale
2. tsnsrv stops (all 64 nodes will disconnect)
3. Caddy restarts with Tailscale plugin
4. Single ephemeral node registers using OAuth

**Deployment time**: ~5-10 minutes (includes build + activation)

### 3. Monitor Deployment

Watch the deployment logs for:
- ✅ Caddy service starting
- ✅ Tailscale plugin initializing
- ✅ OAuth authentication succeeding
- ✅ Ephemeral node registration
- ⚠️ Any errors or warnings

## Post-Deployment Verification

### Immediate Checks (within 5 minutes)

```bash
# 1. Verify Caddy is running with Tailscale
ssh storage "systemctl status caddy"

# 2. Check Caddy logs for Tailscale initialization
ssh storage "journalctl -u caddy -n 100 | grep -i tailscale"

# 3. Verify single Tailscale node
tailscale status | grep caddy
# Or check Tailscale admin console

# 4. Count remaining nodes (should be ~1)
# Check Tailscale admin console - 64 nodes should be gone

# 5. Verify ephemeral flag
# Check node details in Tailscale admin - should show "Ephemeral: Yes"
```

### Service Access Tests (within 10 minutes)

```bash
# Test a few services from Tailnet
curl -I https://jellyfin.bat-boa.ts.net
curl -I https://sonarr.bat-boa.ts.net
curl -I https://radarr.bat-boa.ts.net

# Test Funnel services from public internet (if configured)
curl -I https://jellyfin.bat-boa.ts.net # From non-Tailscale network
```

**Expected**: All services should be accessible with proper authentication redirects

### CPU Monitoring (over 30 minutes)

```bash
# Initial CPU check (right after deployment)
ssh storage "top -bn1 | grep Cpu"

# Wait 10 minutes, check again
sleep 600 && ssh storage "top -bn1 | grep Cpu"

# Wait 30 minutes total, final check
sleep 1200 && ssh storage "top -bn1 | grep Cpu"
```

**Expected CPU usage**: ~2-5% (down from 60.5%)

### Ephemeral Node Testing

```bash
# Restart Caddy to test ephemeral behavior
ssh storage "systemctl restart caddy"

# Wait 30 seconds
sleep 30

# Verify node re-registered
tailscale status | grep caddy

# Check Tailscale admin - should see node disconnect and reconnect
```

**Expected**: Node should automatically re-register as ephemeral

## Success Criteria

- [ ] Deployment completes successfully
- [ ] Single "caddy" Tailscale node visible in admin console
- [ ] Node marked as ephemeral in Tailscale admin
- [ ] 64 tsnsrv nodes removed from Tailscale
- [ ] CPU usage measured at 2-5% (down from 60.5%)
- [ ] All services accessible from Tailnet
- [ ] Funnel services accessible from public internet (if configured)
- [ ] Caddy service stable (no restarts)
- [ ] No errors in Caddy logs
- [ ] Ephemeral node re-registers after Caddy restart

## Rollback Plan

If issues occur during or after deployment:

```bash
# 1. Revert the commit
git revert HEAD

# 2. Redeploy previous configuration
just deploy storage

# 3. Verify tsnsrv is running again
ssh storage "systemctl status tsnsrv"

# 4. Check services are accessible
```

**When to rollback**:
- Services become inaccessible
- Caddy fails to start
- OAuth authentication fails
- CPU usage doesn't improve

## Post-Deployment Tasks

After successful deployment and verification:

1. **Update task statuses**:
   - Mark task-30 as Done (if not already)
   - Mark task-31 as Done
   - Mark this task as Done

2. **Document the deployment**:
   - Add notes to IMPLEMENTATION_PLAN.md (if it still exists)
   - Record actual CPU usage improvement
   - Note any issues encountered

3. **Monitor for 24 hours**:
   - Check CPU usage periodically
   - Monitor Caddy logs for errors
   - Verify services remain accessible
   - Confirm ephemeral node stability

4. **Clean up** (optional):
   - Remove IMPLEMENTATION_PLAN.md if deployment is stable
   - Archive completed tasks

## Metrics to Record

Capture these metrics for comparison:

**Before Deployment**:
- Tailscale nodes: _____ (expected: ~64)
- CPU usage: _____ (expected: ~60.5%)
- tsnsrv processes: _____ (expected: ~64)

**After Deployment**:
- Tailscale nodes: _____ (expected: 1)
- CPU usage: _____ (expected: ~2-5%)
- tsnsrv processes: _____ (expected: 0)

**Improvement**:
- Nodes reduced by: _____ (expected: 63 nodes, 98.4%)
- CPU reduced by: _____ (expected: ~55%, from 60.5% to 2-5%)

## Dependencies

- Depends on: task-30 ✅ (OAuth package)
- Depends on: task-31 ✅ (Gateway integration)
- Related: task-29 (initial investigation)
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Deployment completes without errors
- [ ] #2 Single 'caddy' Tailscale node visible in admin console
- [ ] #3 Node is marked as ephemeral
- [ ] #4 64 tsnsrv nodes removed from Tailscale
- [ ] #5 CPU usage measured at 2-5% (down from 60.5%)
- [ ] #6 All services accessible from Tailnet
- [ ] #7 Funnel services accessible from public internet
- [ ] #8 Caddy service runs stably with no crashes
- [ ] #9 No errors in Caddy logs related to Tailscale
- [ ] #10 Ephemeral node successfully re-registers after Caddy restart
- [ ] #11 Deployment metrics recorded
- [ ] #12 24-hour stability confirmed
<!-- AC:END -->
