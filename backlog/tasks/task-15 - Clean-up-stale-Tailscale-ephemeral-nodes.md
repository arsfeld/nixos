---
id: task-15
title: Clean up stale Tailscale ephemeral nodes
status: Done
assignee: []
created_date: '2025-10-15 20:18'
updated_date: '2025-10-15 22:28'
labels:
  - infrastructure
  - tailscale
  - cleanup
dependencies: []
priority: medium
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
After multiple tsnsrv-all restarts, there are many stale ephemeral Tailscale nodes that need to be cleaned up. These stale nodes cause DNS conflicts and connection timeouts.

The issue: When tsnsrv-all restarts with fresh state directories, it creates new ephemeral nodes but old ones don't immediately disappear from Tailscale, causing DNS to resolve to offline nodes.

Solution: Use the Tailscale API to periodically clean up stale nodes, or implement a pre-start cleanup script in the tsnsrv-all systemd service.
<!-- SECTION:DESCRIPTION:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
## Solution: Standalone Cleanup Script

Created a standalone shell script at `scripts/cleanup-tailscale-nodes.sh` that uses the Tailscale API to delete stale ephemeral nodes.

### What Was Built

**Standalone Script** (`scripts/cleanup-tailscale-nodes.sh`)
- Uses Tailscale API to list and delete stale ephemeral nodes
- Filters by tag and age
- Supports dry-run mode to preview deletions
- Flexible options for custom tailnet, tag, max age, and API key location
- Clear output showing what was deleted

### Why Standalone Script (No NixOS Module)

Since all tsnsrv nodes are ephemeral, there's no need for automatic cleanup that runs before service starts or on a timer. A simple standalone script that can be run manually when needed is the right solution.

### Usage

```bash
# Basic usage
./scripts/cleanup-tailscale-nodes.sh

# Dry run (preview only)
./scripts/cleanup-tailscale-nodes.sh --dry-run

# Custom API key location
./scripts/cleanup-tailscale-nodes.sh --api-key .tailscale-api-key

# Show all options
./scripts/cleanup-tailscale-nodes.sh --help
```

### Setup

1. Generate a Tailscale API key with Devices read/write permissions
2. Store it in a local file:
   ```bash
   echo "tskey-api-xxxxx" > .tailscale-api-key
   chmod 600 .tailscale-api-key
   ```
3. Run the script when needed

Full documentation: `docs/tailscale-cleanup-setup.md`

### When to Use

Run this script manually when:
- You notice DNS conflicts or connection timeouts to services  
- After restarting tsnsrv services multiple times
- You see many stale nodes in Tailscale admin console
- As part of maintenance after infrastructure changes
<!-- SECTION:NOTES:END -->
