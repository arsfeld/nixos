---
id: task-4
title: Investigate and compare OAuth implementations for caddy-tailscale
status: Done
assignee:
  - '@claude'
created_date: '2025-10-12 14:48'
updated_date: '2025-10-12 14:51'
labels:
  - infrastructure
  - research
dependencies: []
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Compare the OAuth implementations between PR #109 (erikologic), the chrishoage fork, and determine which approach to use. Check if PR #109 provides the OAuth client auth we need for our use case.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Review PR #109 implementation and features
- [x] #2 Review chrishoage fork implementation
- [x] #3 Determine which approach best fits our needs (single OAuth key for multiple services)
- [x] #4 Document findings and recommendation
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
## PR #109 (erikologic) Analysis
- Adds OAuth client credentials support (TS_CLIENT_ID + TS_CLIENT_SECRET)
- Supports multi-node configuration with single OAuth key
- Allows ephemeral nodes and tagging
- Still in PR review, not merged yet
- Branch: erikologic/caddy-tailscale@supports-oauth

## chrishoage Fork Analysis
- Not a special OAuth fork, just has dependency updates
- Commit 559d3be updates Go to 1.24.0 and Tailscale to v1.84.3
- No unique OAuth features compared to official plugin
- Was likely referenced incorrectly in original package

## Recommendation
**Use erikologic/caddy-tailscale (PR #109 code)**

Reasons:
1. ✅ Full OAuth client credentials support (TS_CLIENT_ID + TS_CLIENT_SECRET)
2. ✅ Single OAuth key for multiple nodes/services - exactly our use case
3. ✅ Supports ephemeral nodes and tagging
4. ✅ Active development (PR opened Sept 2025)
5. ✅ Clean implementation - generates auth keys at runtime from OAuth creds

Implementation approach:
- Vendor erikologic/caddy-tailscale source into our repo
- Build Caddy with this plugin using Nix
- Use existing tailscale-key.age as OAuth client secret
- Configure with TS_AUTHKEY=$CLIENT_SECRET and TS_API_CLIENT_ID

This gives us the 85% resource reduction (58 processes → 1 Caddy instance) we're targeting.
<!-- SECTION:NOTES:END -->
