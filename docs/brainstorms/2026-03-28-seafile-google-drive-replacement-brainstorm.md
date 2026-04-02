# Brainstorm: Seafile as Lightweight Google Drive Replacement

**Date:** 2026-03-28
**Status:** Draft

## What We're Building

A self-hosted file sync and sharing solution using **Seafile**, replacing Nextcloud's file management role. Seafile will be hosted on **storage** as a native NixOS service and accessed from **raider** via a Home Manager-managed sync client.

### Core Requirements

- **File sync client** — background daemon keeping a local folder on raider in sync with the server
- **Web UI** — browse, upload, download files via Seahub web interface
- **Lightweight** — must use significantly fewer resources than Nextcloud (~100MB RAM vs 500MB+)
- **Good Linux support** — native desktop client available in nixpkgs

### Non-Requirements (for now)

- Office/document editing
- File sharing links (nice to have, Seafile supports them, but not driving the decision)
- Calendar/contacts/PIM (separate concern from file storage)

## Why Seafile

### Over Nextcloud (current)

Nextcloud is too heavy for what's primarily a file sync use case. It bundles PIM, apps ecosystem, and collaboration features that add resource overhead. Seafile is purpose-built for file sync with block-level deduplication and a proven Linux client.

### Over OpenCloud (already deployed)

OpenCloud/oCIS is a newer ecosystem with potentially rough edges on desktop client compatibility. Seafile has been battle-tested since 2012 with mature sync clients.

### Over Syncthing + Filebrowser (already running)

While both are already deployed, they don't provide a unified "drive" experience. Two separate tools with no integrated file versioning or sharing.

## Key Decisions

1. **Deployment method:** Native NixOS service (`services.seafile`) — more integrated with the system, declarative configuration
2. **Data location:** `/mnt/storage/data/Seafile` — on the large storage volume, using a new path pattern for services with special storage needs
3. **Client on raider:** Home Manager systemd user service — declarative, consistent with the rclone gdrive mount pattern in `home/home.nix`
4. **Gateway integration:** Expose via `media.gateway.services` at `seafile.arsfeld.one` with Caddy reverse proxy, following existing patterns
5. **Auth:** Seafile has its own auth — set `bypassAuth = true` in gateway config (like Nextcloud)

## Architecture Sketch

```
raider (desktop)                         storage (server)
┌──────────────────┐                    ┌──────────────────────────┐
│ seafile-cli       │◄──── sync ────►  │ seafile-server (native)  │
│ (Home Manager     │                   │   - seahub (web UI)      │
│  systemd service) │                   │   - seafile daemon       │
│                   │                   │   - ccnet (network)      │
│ ~/Seafile/        │                   │                          │
│  (synced folder)  │                   │ Data: /mnt/storage/data/ │
│                   │                   │       Seafile/            │
│ Browser ──────────┼── HTTPS ────────► │                          │
│                   │                   │ Caddy → seafile:8082     │
└──────────────────┘                    │ (seafile.arsfeld.one)    │
                                        └──────────────────────────┘
```

## Integration Points

- **Gateway:** `seafile.arsfeld.one` via Caddy (storage's wildcard cloudflared tunnel handles routing)
- **Tailscale:** Optionally expose via tsnsrv at `seafile.bat-boa.ts.net`
- **Backups:** Seafile data under `/mnt/storage/data/Seafile` should be included in rustic backup schedule
- **Database:** Seafile needs MySQL/MariaDB or SQLite. Native NixOS module handles this.

## Resolved Questions

1. **Database choice:** SQLite — simpler, no extra service, sufficient for single-user use case

## Deferred Questions

These will be revisited after Seafile is deployed and tested:

1. **Nextcloud fate:** Keep for PIM (calendar/contacts/tasks) or remove entirely? Decide after evaluating Seafile in practice.
2. **Mobile access:** Mobile apps vs web UI — focus on server + desktop first, decide later.

## Open Questions

None — all questions resolved or deferred.

## Migration Plan

Manual migration — start fresh in Seafile, move important files over via the sync client or web UI. No scripted bulk import needed.

## Prior Art in This Repo

- `hosts/storage/services/files.nix` — Nextcloud config (what we're replacing for files)
- `modules/constellation/opencloud.nix` — OpenCloud module (alternative considered)
- `home/home.nix:519-536` — rclone FUSE mount pattern (similar to what we'll do for Seafile client)
- `modules/media/__mkService.nix` — service declaration pattern for gateway integration
