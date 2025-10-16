---
id: task-20
title: Optimize Tailscale netmon CPU usage in tsnsrv
status: Done
assignee: []
created_date: '2025-10-16 02:40'
updated_date: '2025-10-16 03:11'
labels:
  - performance
  - tsnsrv
  - optimization
  - netmon
dependencies:
  - task-19
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
After disabling portlist, tsnsrv still consumes 60.5% CPU on storage (57 services). Profiling shows ~90% of remaining CPU is from Tailscale's network monitor (netmon) polling network interfaces.

## Current State
- CPU usage: 60.5% (36.37s/60s)
- Primary bottleneck: `net.interfaceAddrTable` (72% cumulative)
- Secondary: `net.interfaceTable` (20% cumulative)
- Root cause: netmon polls network interfaces ~every second via netlink syscalls

## Goal
Reduce netmon CPU overhead to achieve target <30% CPU usage for 57 services.

## Background
Task-19 profiling identified netmon as the next optimization target after successfully eliminating portlist (46.5% CPU reduction). The network monitor polls for interface changes (WiFi → Ethernet, IP changes, etc.) but the default polling interval may be too aggressive for a static server environment.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Research Tailscale netmon configuration options and environment variables
- [ ] #2 Test netmon throttling/disabling approaches on storage
- [ ] #3 Collect new pprof profiles to measure CPU reduction
- [ ] #4 Achieve target CPU usage <30% for 57 services
- [ ] #5 Document findings and update tsnsrv implementation
- [x] #6 If netmon can't be optimized, evaluate architectural alternatives
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
## Research Findings - 2025-10-16

### Summary

After extensive research into Tailscale's netmon (network monitor) component, **there is no simple configuration option to disable or throttle network monitoring**. Unlike portlist (which had `TS_DEBUG_DISABLE_PORTLIST`), netmon is a core component without environment variable controls.

### Technical Analysis

**Current CPU Profile** (from task-19):
- Total CPU: 60.5% (36.37s/60s) for 57 services
- `net.interfaceAddrTable`: 72.09% cumulative (26.22s) - Network interface address enumeration
- `net.interfaceTable`: 20.18% cumulative (7.36s) - Network interface list retrieval  
- `syscall.NetlinkRIB`: 90.16% cumulative (32.79s) - Low-level netlink syscalls

**Root Cause**: Tailscale's netmon polls network interfaces via Go's `net` package (which uses Linux netlink) to detect connectivity changes (WiFi → Ethernet, IP changes, interface up/down events).

### netmon Architecture

**Purpose**: Monitor network state changes to enable Tailscale to:
- Detect when devices move between networks
- Re-establish connections after network changes
- Update routes when interfaces change
- Handle sleep/wake cycles

**Implementation**:
- Initialized automatically by `tsnet.Server` during startup (cli.go:663-669)
- Created via `netmon.New(eventBus, logger)` in tsnet.go
- Polling intervals:
  - Wall time check: 15 seconds (for sleep/wake detection)
  - Interface polling: Event-driven + periodic (appears to be ~1 second based on CPU usage)
  - Debounce delay: 250ms between state change notifications

**Two Monitor Types**:
1. `netmon.New()` - Active monitoring (production use)
2. `netmon.NewStatic()` - Static snapshot (tests/CLI tools only)

### Research Attempts

**1. Environment Variables** ❌
- Searched for `TS_DEBUG_DISABLE_NETMON`, `TS_NETMON_INTERVAL`, etc.
- **Finding**: No such variables exist in Tailscale codebase
- Tailscale deliberately doesn't document most TS_DEBUG variables to prevent Hyrum's Law
- Only `TS_DEBUG_DISABLE_PORTLIST` exists (added for issue #10430)

**2. Configuration Options** ❌
- Examined `tsnet.Server` struct and netmon.Monitor API
- **Finding**: No configuration fields for polling intervals or disabling netmon
- netmon is created internally by tsnet with no exposure to users

**3. NewStatic() Approach** ⚠️ **RISKY**
- `netmon.NewStatic()` provides one-time snapshot without monitoring
- **Problem**: Would prevent Tailscale from detecting:
  - Network interface changes
  - IP address changes
  - Network failures/recovery
  - Sleep/wake events
- **Conclusion**: Unsuitable for production - would break core Tailscale functionality

### Optimization Options

#### Option 1: Accept Current Performance ⭐ RECOMMENDED
**Pros**:
- 60.5% CPU for 57 services = 1.06% per service (acceptable overhead)
- Network monitoring is essential for reliable operation
- Matches expected behavior for production Tailscale deployments

**Cons**:
- No improvement from current state

**Recommendation**: This is standard Tailscale behavior. The CPU usage is reasonable for the number of services.

#### Option 2: File Upstream Feature Request
**Approach**: Request `TS_DEBUG_DISABLE_NETMON` or `TS_NETMON_POLL_INTERVAL` environment variable from Tailscale team

**Pros**:
- Proper long-term solution
- Follows precedent of `TS_DEBUG_DISABLE_PORTLIST`
- Would benefit other users with static server deployments

**Cons**:
- No immediate benefit
- May be rejected if Tailscale considers netmon essential
- Timeline uncertain

**Next Steps**:
- File issue at https://github.com/tailscale/tailscale/issues
- Reference this use case: 57 services, static server, unchanging network
- Link to issue #10430 (portlist) as precedent

#### Option 3: Architectural Consolidation
**Approach**: Reduce number of `tsnet.Server` instances by sharing servers across multiple services

**Current**: 57 services = 57 tsnet.Server instances = 57 netmon instances
**Proposed**: Group services to share tsnet instances (e.g., 5-10 instances)

**Pros**:
- Could reduce netmon CPU proportionally (57 → 10 instances = ~82% reduction)
- Each tsnet.Server runs its own netmon, so fewer servers = less polling

**Cons**:
- Major architectural change to tsnsrv
- Complicates service isolation and management
- More complex failure modes
- Significant development effort

**Feasibility**: Possible but requires tsnsrv refactoring to support multi-service routing per tsnet instance

#### Option 4: Kernel-Level Optimization (netlink)
**Approach**: Investigate if Go's netlink usage could be optimized

**Pros**:
- Would benefit all Go applications using net package

**Cons**:
- Outside our control (Go stdlib)
- Likely already optimized
- May not be the actual bottleneck

### Conclusion & Recommendations

**Primary Finding**: No simple optimization path exists for netmon CPU usage.

**Immediate Action**: **Accept current performance** (Option 1)
- 60.5% CPU is acceptable for 57 services on a server
- Attempting to disable netmon would compromise Tailscale functionality
- This is expected behavior for production tsnet deployments

**Long-term Action**: **File upstream feature request** (Option 2)  
- Request TS_DEBUG_DISABLE_NETMON or TS_NETMON_POLL_INTERVAL
- Provide use case: static servers with unchanging network topology
- Reference issue #10430 as precedent

**Future Consideration**: **Architectural consolidation** (Option 3)
- Only pursue if CPU becomes a bottleneck (>80%)
- Requires cost/benefit analysis
- Substantial engineering effort

### Key Learnings

1. **netmon is essential**: Unlike portlist, network monitoring is core to Tailscale's reliable operation
2. **No disable switch**: Tailscale doesn't expose netmon configuration deliberately
3. **Per-instance cost**: Each tsnet.Server creates its own netmon, so 57 services = 57 monitors
4. **Standard behavior**: Current CPU usage aligns with expected tsnet overhead for multiple instances

### Files Referenced

**tsnsrv source**:
- `/home/arosenfeld/Projects/tsnsrv/cli.go:656-793` - ValidTailnetSrv.Run() method
- `/home/arosenfeld/Projects/tsnsrv/orchestrator.go` - Multi-service orchestration

**Tailscale source** (github.com/tailscale/tailscale):
- `tsnet/tsnet.go` - tsnet.Server netmon initialization
- `net/netmon/netmon.go` - Monitor implementation, polling intervals
- `net/netmon` package docs - NewStatic() vs New() comparison

**Related issues**:
- https://github.com/tailscale/tailscale/issues/10430 - portlist CPU (precedent)
- https://github.com/tailscale/tailscale/issues/10954 - High CPU after tailscale serve
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
## Task Outcome - 2025-10-16

**Decision**: Accept current 60.5% CPU usage as expected behavior for 57 tsnet.Server instances.

**Rationale**:
- No configuration options exist to disable or throttle netmon
- netmon is essential for Tailscale's core functionality (network change detection)
- 1.06% CPU per service is reasonable overhead
- Disabling netmon would break reliability (can't detect network changes, failures, IP changes)

**Next Steps**:
- Created task-22 to investigate cloudflared as alternative to tsnsrv
- Long-term: Consider filing upstream feature request for TS_DEBUG_DISABLE_NETMON
- Future: If CPU exceeds 80%, revisit architectural consolidation (Option 3)

**Acceptance Criteria Updates**:
- #1 ✓ Research completed - no env vars or config options found
- #2 ✗ No throttling approaches available to test
- #3 ✗ No optimization to profile
- #4 ✗ Goal of <30% CPU not achievable without upstream changes or architecture refactor
- #5 ✓ Findings documented in Implementation Plan
- #6 ✓ Evaluated all architectural alternatives (Options 1-4)
<!-- SECTION:NOTES:END -->
