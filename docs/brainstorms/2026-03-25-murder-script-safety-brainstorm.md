# Brainstorm: Make `murder` script filtering robust

**Date:** 2026-03-25
**Status:** Complete

## What We're Building

The `murder` script (`home/scripts/murder`) is a process killer that works by PID, name, or port. When killing by port, `lsof` can return system processes (like systemd) that the user doesn't care about, creating noisy and alarming prompts.

The current fix uses hardcoded lists of protected PIDs and process names — fragile and always incomplete.

## Why This Approach

**Key insight from the user:** Permissions already handle safety. A non-root user *can't* kill root processes — `kill` will just fail. The real problem is **noise**, not safety. The script shouldn't prompt about processes the user can't kill anyway.

**Solution:** Filter by UID. Only show processes owned by the current user. This:

- Naturally excludes all system processes (systemd, sshd, init, kernel threads, etc.)
- Requires zero hardcoded lists
- Adapts to any system without configuration
- Is the correct semantic filter — "show me *my* stuff"

## Key Decisions

- **UID-based filtering replaces all hardcoded lists** — no `PROTECTED_PIDS`, no `PROTECTED_NAMES`
- **Skip silently in list modes** (port/name) — don't clutter output with "skipping PID 1"
- **Print a message in direct PID mode** — if `murder 1` is called, tell the user why it was skipped so they're not confused by silence
- **No sudo special-casing** — if run as root, UID is 0 and it matches root processes. That's intentional; if you're root, you know what you're doing

## Open Questions

None — approach is straightforward.
