# Brainstorm: Automatic /home Snapshots on Raider

**Date:** 2026-03-28
**Status:** Complete

## What We're Building

Automatic btrfs snapshots of `/home` on raider using **btrbk**, providing fast local recovery from accidental file deletions. Snapshots use a tiered retention policy (hourly/daily/weekly) and are browsable via a well-known filesystem path.

This complements the existing Rustic remote backups -- Rustic handles off-site disaster recovery, while btrbk provides instant local file recovery without network round-trips.

## Why This Approach

**btrbk** was chosen over snapper and custom systemd timers because:

- Purpose-built for btrfs snapshot management -- does one thing well
- NixOS has a built-in `services.btrbk` module -- no custom plumbing needed
- Simple config-file driven, supports tiered retention natively
- Snapshots are standard btrfs subvolumes, browsable via filesystem path
- Lightweight with no dbus or other heavyweight dependencies

**Raider-only** (not a constellation module) because:
- Only raider currently needs this
- Other hosts have different filesystem layouts
- Avoids premature abstraction -- can be extracted later if needed

## Key Decisions

1. **Tool:** btrbk with NixOS `services.btrbk` module
2. **Scope:** `/home` subvolume on raider (Samsung 850 EVO 1TB, btrfs)
3. **Retention:** Tiered -- hourly snapshots pruned to daily after 24h, then weekly after 30d
4. **Restore UX:** Browsable snapshot directory (e.g., `/home/.snapshots/`)
5. **Placement:** `hosts/raider/` configuration, not a shared module
6. **Relationship to Rustic:** Complementary -- btrbk for fast local recovery, Rustic for remote/disaster recovery

## Context

- Raider's `/home` is a dedicated btrfs partition on Samsung 850 EVO 1TB SSD
- Subvolume structure: single `/home` subvolume (from disko-config.nix)
- Existing backup: Rustic weekly to storage.bat-boa.ts.net (remote, file-level)
- Primary use case: recovering accidentally deleted files quickly
