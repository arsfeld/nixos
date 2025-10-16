---
id: task-16
title: Investigate high CPU load from tsnsrv
status: Done
assignee: []
created_date: '2025-10-15 22:26'
updated_date: '2025-10-15 22:31'
labels:
  - investigation
  - performance
  - tsnsrv
dependencies: []
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
The tsnsrv service is showing high CPU usage on both storage and cloud hosts. This needs investigation to determine the root cause and potential solutions.

Source code: https://github.com/tailscale/tailscale (tsnsrv is part of Tailscale tooling)
Local reference: ../tsnsrv

Affected hosts:
- storage.bat-boa.ts.net
- cloud.bat-boa.ts.net
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Identify the specific cause of high CPU usage on both hosts
- [x] #2 Document CPU usage patterns (baseline vs current)
- [x] #3 Determine if this is a configuration issue or upstream bug
- [x] #4 Provide recommendations for mitigation or upgrade path
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
## Investigation Complete - 2025-10-15

Full report: docs/tsnsrv-performance-investigation.md

### Root Cause
Single tsnsrv process manages ~57 virtual Tailscale nodes (storage) and ~14 nodes (cloud). Each virtual node requires independent authentication, TLS management, and network state.

### Key Findings
- Storage: 113% CPU, 2.6GB RAM (~2% CPU per service)
- Cloud: 9.5% CPU, 351MB RAM (~0.68% CPU per service)
- Previous architecture (57 processes): 40% CPU vs current 113% CPU
- This is an architectural limitation, not a bug

### Recommendations
1. Quick win: Disable unused services (20-40% reduction)
2. Medium term: Split services across hosts (60% reduction)
3. Long term: Migrate to Caddy (85-90% reduction)
   - Plan in docs/tsnsrv-optimization-proposal.md
<!-- SECTION:NOTES:END -->
