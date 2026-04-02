# Brainstorm: Container Image Watcher

**Date:** 2026-03-24
**Status:** Ready for planning

## What We're Building

An opt-in, per-service container image watcher that polls GHCR every 5 minutes and automatically pulls + restarts containers when a new image is detected. Sends ntfy notifications on updates.

### Motivation

finance-tracker (`ghcr.io/arsfeld/finance-tracker:latest`) and mydia (`ghcr.io/getmydia/mydia:master`) are under active development with images built by GitHub Actions. The existing daily `podman-image-pull` timer is too slow for the dev feedback loop — changes should be live within minutes, not hours.

### Target Services (Initial)

- **finance-tracker** — own repo, `ghcr.io/arsfeld/finance-tracker:latest`
- **mydia** — third-party repo (`ghcr.io/getmydia/mydia:master`), cannot modify its CI

## Why This Approach

### Polling over webhooks/CI triggers

- mydia's GitHub Actions can't be modified, ruling out webhook or SSH-from-CI approaches
- Polling the registry is simple, requires no inbound connectivity, and works uniformly for any GHCR image regardless of who owns the repo
- 5-minute polling for 2 images is negligible load on GHCR

### Per-service systemd timers over a single watcher

- Each watched service gets its own systemd timer + oneshot service
- A failure or hang in one image pull doesn't block others
- Per-service logs make debugging straightforward
- Fits the NixOS pattern of generating per-service systemd units
- Extra units are negligible for 2-3 services

### Opt-in via mkService flag

- Add a `watchImage = true` (or similar) flag to the mkService helper
- Any service can opt in without special-casing
- Keeps the mechanism general while only activating where needed

## Key Decisions

1. **Polling frequency:** 5 minutes — fast enough for active dev, light enough for 2 images
2. **Trigger mechanism:** Registry polling (not webhook/CI) — works for repos we don't control
3. **Architecture:** Per-service systemd timer + oneshot — independent, resilient
4. **Scope:** Opt-in per service via mkService flag — general mechanism, not hardcoded
5. **Notifications:** ntfy on successful image update + container restart
6. **Relationship to daily pull:** The daily `podman-image-pull` continues for all services; the watcher is an additional, faster check for opted-in services

## Open Questions

None — all key decisions resolved through brainstorming.

## Constraints

- Must work with Podman (storage host uses Podman, not Docker)
- Reuse the existing pull-and-compare-digest pattern from `podman-image-pull`
- ntfy is already configured in the flake — use the existing setup
- Should not interfere with the existing daily `podman-image-pull` timer
