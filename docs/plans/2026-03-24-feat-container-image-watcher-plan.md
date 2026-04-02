---
title: "feat: Add opt-in per-service container image watcher"
type: feat
status: completed
date: 2026-03-24
origin: docs/brainstorms/2026-03-24-container-image-watcher-brainstorm.md
---

# feat: Add opt-in per-service container image watcher

## Overview

Add a `watchImage` flag to the `media.containers` submodule that generates per-service systemd timers polling GHCR every 5 minutes. When a new image digest is detected, the container is automatically restarted and an ntfy notification is sent. Initial targets: finance-tracker and mydia.

## Problem Statement / Motivation

finance-tracker and mydia are under active development with CI pushing images to GHCR on every merge. The existing daily `podman-image-pull` timer means changes take up to 24 hours to deploy. Developers need a feedback loop of minutes, not hours (see brainstorm: `docs/brainstorms/2026-03-24-container-image-watcher-brainstorm.md`).

## Proposed Solution

### Architecture

Add two new options to the `media.containers.<name>` submodule in `containers.nix`:

- `watchImage` (bool, default `false`) — enables the per-service watcher
- `watchImageInterval` (str, default `"5min"`) — polling interval

For each container with `watchImage = true`, `containers.nix` generates:
- A systemd oneshot service (`image-watch-<name>`) that pulls the image, compares digests, restarts if changed, and sends ntfy notification
- A systemd timer (`image-watch-<name>`) using monotonic scheduling (`OnBootSec` + `OnUnitActiveSec`)

Watched containers are excluded from the daily `podman-image-pull` loop in `podman.nix` to avoid race conditions and duplicate pulls.

### Data Flow

```
Timer fires (every 5 min)
  → oneshot runs
  → podman inspect <container> for current image ID
  → podman pull <image>
  → podman inspect <image> for new image ID
  → if IDs differ:
      → systemctl restart podman-<name>
      → curl ntfy notification (fire-and-forget)
  → if IDs match: exit silently
```

## Technical Considerations

### Race condition with daily pull (resolved)

Watched containers will be excluded from `podman-image-pull` by filtering on `media.containers` metadata. This requires `podman.nix` to read `config.media.containers` and skip any container where `watchImage = true`. This is the cleanest solution — no duplicate pulls, no concurrent restart risk.

### Timer type: monotonic vs. wallclock

Use `OnBootSec = "2min"` + `OnUnitActiveSec` (monotonic timer). Do NOT add `Persistent = true` — it has no effect on monotonic timers. The 2-minute boot delay gives podman time to initialize.

### ntfy integration

- Topic: `container-updates`
- Notifications on both success AND failure (pull failures, restart failures)
- Success message includes service name, image ref, and shortened old/new digests
- Failure message includes service name and error context
- ntfy failures are non-fatal (curl with `|| true`)

### Network and podman readiness

- Systemd dependencies: `wants = ["podman.service"]`, `after = ["podman.service" "network-online.target"]`
- Include the podman wait loop from existing daily pull as a safety net

### Stopped/non-existent container

Follow existing behavior: if `current_id == "none"` (container never started), pull the image but skip restart. The container's own systemd service handles initial startup.

### Security posture

Match existing `podman-image-pull`: `Type = "oneshot"`, `User = "root"`. No additional hardening — consistent with current patterns.

## Files to Modify

| File | Change |
|------|--------|
| `modules/media/containers.nix` | Add `watchImage` and `watchImageInterval` options to submodule; generate per-service systemd timer+service for watched containers |
| `modules/media/__mkService.nix` | Add `watchImage` parameter (default `false`), pass through to `media.containers.<name>` |
| `modules/constellation/podman.nix` | Filter out watched containers from daily `podman-image-pull` script |
| `modules/services/media-apps.nix` | Add `watchImage = true` to mydia's mkService call |
| `hosts/storage/services/home.nix` | Add `watchImage = true` to finance-tracker's mkService call |

## Acceptance Criteria

- [x] `watchImage` option added to `media.containers` submodule (`containers.nix`)
- [x] `watchImageInterval` option added with `"5min"` default (`containers.nix`)
- [x] `watchImage` parameter added to `__mkService.nix` and threaded through
- [x] Per-service systemd timer + oneshot generated for each `watchImage = true` container
- [x] Oneshot script: pulls image, compares digest, restarts container on change
- [x] ntfy notification sent on successful update (topic: `container-updates`)
- [x] ntfy notification sent on failure (pull or restart failure)
- [x] ntfy failure does not block container restart
- [x] Watched containers excluded from daily `podman-image-pull` loop
- [x] finance-tracker has `watchImage = true`
- [x] mydia has `watchImage = true`
- [x] `nix build .#nixosConfigurations.storage.config.system.build.toplevel` succeeds

## Implementation Plan

### Phase 1: Module options and timer generation (`containers.nix`)

Add `watchImage` (bool) and `watchImageInterval` (str) to the submodule options. In the `config` block, filter `deployedContainers` for `watchImage = true` and generate `systemd.timers` and `systemd.services` using `mapAttrsToList` + `mkMerge` (same pattern as the existing `systemd.services` block at line 201).

**Timer config:**
```nix
systemd.timers."image-watch-${name}" = {
  wantedBy = ["timers.target"];
  timerConfig = {
    OnBootSec = "2min";
    OnUnitActiveSec = container.watchImageInterval;
  };
};
```

**Oneshot script** (per container, adapted from `podman.nix` lines 86-137):
```bash
# Wait for podman
while ! podman info >/dev/null 2>&1; do sleep 1; done

image_name="<container.image>"
container_name="<name>"

current_id=$(podman inspect "$container_name" -f '{{.Image}}' 2>/dev/null || echo "none")

if ! podman pull "$image_name"; then
  curl -s -d "Failed to pull $image_name" \
    -H "Title: Image Pull Failed: $container_name" \
    -H "Priority: 4" -H "Tags: warning" \
    https://ntfy.arsfeld.one/container-updates || true
  exit 1
fi

new_id=$(podman inspect "$image_name" -f '{{.Id}}' 2>/dev/null)

if [ "$current_id" != "none" ] && [ "$current_id" != "$new_id" ]; then
  echo "New image detected for $container_name, restarting..."
  if systemctl restart "podman-$container_name"; then
    curl -s -d "Updated $image_name (${current_id:0:12} → ${new_id:0:12})" \
      -H "Title: Container Updated: $container_name" \
      -H "Priority: 3" -H "Tags: package,white_check_mark" \
      https://ntfy.arsfeld.one/container-updates || true
  else
    curl -s -d "Pulled new image but restart failed for $container_name" \
      -H "Title: Container Restart Failed: $container_name" \
      -H "Priority: 4" -H "Tags: warning" \
      https://ntfy.arsfeld.one/container-updates || true
    exit 1
  fi
fi
```

### Phase 2: mkService passthrough (`__mkService.nix`)

Add `watchImage ? false` to the parameter set. In the container branch, include it in the attrset merged into `media.containers.<name>`:

```nix
media.containers.${name} = {
  listenPort = port;
  inherit image settings watchImage;
} // container;
```

### Phase 3: Exclude from daily pull (`podman.nix`)

Modify the `podman-image-pull` script to skip containers that have `watchImage = true`. This requires reading `config.media.containers` in `podman.nix`:

```nix
# In the concatMapStrings, filter out watched containers
watchedContainers = lib.optionalAttrs (config ? media && config.media ? containers)
  (lib.filterAttrs (_: c: c.watchImage or false) config.media.containers);

# Existing loop filters them out:
lib.concatMapStrings (name: ...)
  (lib.filter (name: !(watchedContainers ? ${name}))
    (builtins.attrNames config.virtualisation.oci-containers.containers))
```

### Phase 4: Enable on target services

- `hosts/storage/services/home.nix`: Add `watchImage = true;` to finance-tracker
- `modules/services/media-apps.nix`: Add `watchImage = true;` to mydia

### Phase 5: Build and verify

```bash
nix develop -c nix build .#nixosConfigurations.storage.config.system.build.toplevel
```

Verify generated units:
```bash
# Check timer exists
cat result/etc/systemd/system/image-watch-finance-tracker.timer
cat result/etc/systemd/system/image-watch-finance-tracker.service
cat result/etc/systemd/system/image-watch-mydia.timer
# Verify finance-tracker and mydia are NOT in podman-image-pull script
cat result/etc/systemd/system/podman-image-pull.service
```

## Dependencies & Risks

- **GHCR rate limits**: 5-minute polling for 2 images is ~576 pulls/day. Well within GHCR limits (authenticated: 1000/hr, unauthenticated: lower but sufficient).
- **Brief service downtime during restart**: Expected and acceptable for dev services. No zero-downtime restart needed.
- **`podman.nix` → `media.containers` coupling**: The daily pull exclusion introduces a dependency from `podman.nix` on `media.containers`. Use `lib.optionalAttrs` to make it graceful when `media.containers` is not defined (e.g., hosts without media services).

## Sources & References

- **Origin brainstorm:** [docs/brainstorms/2026-03-24-container-image-watcher-brainstorm.md](docs/brainstorms/2026-03-24-container-image-watcher-brainstorm.md) — Key decisions: 5-min polling, per-service timers, opt-in flag, ntfy notifications, registry polling over webhooks
- **Existing pull logic:** `modules/constellation/podman.nix:86-137`
- **Dynamic timer pattern:** `modules/check-stock.nix` (per-item timer generation)
- **ntfy shell pattern:** `home/scripts/claude-notify`
- **mkService helper:** `modules/media/__mkService.nix`
- **Container submodule:** `modules/media/containers.nix:44-168`
