---
id: task-61
title: Verify messages in router about own address
status: Done
assignee: []
created_date: '2025-10-18 04:18'
updated_date: '2025-10-18 04:31'
labels: []
dependencies: []
priority: medium
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
SSH into router (ssh root@router) and check system messages/logs for messages related to "own address". This may be related to network configuration or interface issues.
<!-- SECTION:DESCRIPTION:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
## Investigation Results - UPDATED WITH WIFI MESH CONTEXT

**Date:** 2025-10-18

**Context:** No physical cable loop exists. WiFi mesh system is in use.

**Root Cause:**
WiFi mesh with ethernet backhaul is creating a Layer 2 network loop:
```
Router LAN Port (enp4s0) → Mesh Node A → WiFi Mesh → Mesh Node B → Router LAN Port (enp3s0)
```

**Findings:**
The router logs show:
```
br-lan: received packet on enp4s0 with own address as source address (addr:60:be:b4:0d:63:31, vlan:0)
```

Network topology:
- enp3s0 (MAC: 60:be:b4:0d:63:31) - state: **BLOCKING** (no devices learned)
- enp4s0 (MAC: 60:be:b4:0d:63:32) - state: **FORWARDING** (all devices here)
- enp5s0 (MAC: 60:be:b4:0d:63:33) - state: **FORWARDING** (no devices shown)

**Analysis:**
1. WiFi mesh nodes with ethernet backhaul create a redundant path
2. When mesh nodes bridge WiFi and ethernet, they create a Layer 2 loop
3. STP correctly detected this and blocked enp3s0 to prevent broadcast storms
4. Messages occur every 5 minutes when mesh heartbeat/management traffic traverses the loop

**Solutions (pick one):**

### Option 1: Single Ethernet Backhaul (Recommended)
- Connect only ONE mesh node via ethernet to the router
- Other mesh nodes connect wirelessly only
- This eliminates the loop entirely
- Pros: Cleanest solution, no loop messages
- Cons: Slightly less redundancy

### Option 2: Keep Current Setup with STP (What you have now)
- Leave the current configuration as-is
- STP is protecting the network correctly
- Accept the log messages as informational
- Optionally enable `loop-protection.nix` for better STP tuning and log management
- Pros: Maintains redundancy, already working
- Cons: Log spam every 5 minutes

### Option 3: Mesh Router Mode (If supported)
- Configure mesh nodes in "Router Mode" instead of "Bridge/AP Mode"
- This prevents them from bridging WiFi and ethernet
- Requires mesh system to support this mode
- Pros: Can keep multiple ethernet connections
- Cons: May require NAT/routing changes, not all mesh systems support this

### Option 4: Enable RSTP (Rapid Spanning Tree)
- Current config uses standard STP
- RSTP converges faster and may reduce spurious messages
- Modify `network.nix` to use RSTP
- Pros: Faster convergence, better loop handling
- Cons: Doesn't eliminate root cause

**Recommended Action:**
1. **Immediate:** Enable `loop-protection.nix` to reduce log spam (uncomment line 17 in configuration.nix)
2. **Long-term:** Evaluate if you need multiple ethernet backhauls or if one is sufficient
3. If one backhaul is enough: Disconnect enp3s0 ethernet cable, use wireless mesh only

**Current Status:** System is working correctly. STP is protecting the network. No urgent action needed.
<!-- SECTION:NOTES:END -->
