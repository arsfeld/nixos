# Institutional Learnings: Container Image Auto-Updates & Service Patterns

## Research Summary
**Date:** 2026-03-24
**Scope:** Container image auto-updates, Podman integration, systemd timers, ntfy notifications, service restart patterns
**Sources:** 
- Brainstorm document: `docs/brainstorms/2026-03-24-container-image-watcher-brainstorm.md`
- Existing implementations: `modules/constellation/podman.nix`, `hosts/router/ntfy-webhook.nix`
- Service architecture: `modules/media/containers.nix`, `modules/services/media-apps.nix`

---

## Key Findings

### 1. Container Image Auto-Update Pattern (EXISTING)
**File:** `modules/constellation/podman.nix` (lines 77-145)

#### Current Daily Pull Implementation
- **Timer:** `systemd.timers."podman-image-pull"` - runs daily with `OnCalendar = "daily"`
- **Service Type:** oneshot (`Type = "oneshot"`)
- **Logic Pattern:**
  1. Wait for Podman to be available
  2. Iterate all containers in `config.virtualisation.oci-containers.containers`
  3. Get current image ID from running container
  4. Pull new image from registry
  5. Compare digest hashes (current_id vs new_id)
  6. If different, restart container via `systemctl restart podman-${name}`
  7. Exit with error code if any pull/restart fails

#### Key Implementation Details
```bash
# Get current image ID from container
current_id=$(podman inspect "${name}" -f '{{.Image}}' 2>/dev/null || echo "none")

# Pull new image
podman pull "$image_name"

# Get new image ID
new_id=$(podman inspect "$image_name" -f '{{.Id}}' 2>/dev/null)

# Only restart if IDs differ
if [ "$current_id" != "none" ] && [ "$current_id" != "$new_id" ]; then
    systemctl restart "podman-${name}"
fi
```

#### Service Dependencies
- `wants = ["podman.service"]`
- `after = ["podman.service"]`

---

### 2. Proposed Per-Service Image Watcher (BRAINSTORM)
**File:** `docs/brainstorms/2026-03-24-container-image-watcher-brainstorm.md`

#### Key Design Decisions (Already Resolved)
1. **Polling frequency:** 5 minutes (vs daily) - fast enough for active dev
2. **Trigger mechanism:** Registry polling (not webhooks/CI) - works for repos you don't control (mydia)
3. **Architecture:** Per-service systemd timer + oneshot - independent, resilient, good for 2-3 services
4. **Scope:** Opt-in via `watchImage` flag on mkService - general, not hardcoded
5. **Notifications:** ntfy on successful update + container restart
6. **Relationship to daily pull:** The daily `podman-image-pull` continues; watcher is additional, faster check

#### Target Services (Initial)
- `finance-tracker` - own repo, `ghcr.io/arsfeld/finance-tracker:latest`
- `mydia` - third-party repo `ghcr.io/getmydia/mydia:master`, can't modify its CI

#### Why Polling > Webhooks
- mydia's GitHub Actions can't be modified (ruling out webhook/SSH approaches)
- Polling is simple, requires no inbound connectivity
- Works uniformly for any GHCR image regardless of repo owner
- 5-minute polling for 2 images is negligible load

#### Why Per-Service Timers > Single Watcher
- Failure/hang in one image pull doesn't block others
- Per-service logs make debugging straightforward
- Fits NixOS pattern of generating per-service systemd units
- Extra units are negligible for 2-3 services

---

### 3. NTFy Notification Infrastructure (EXISTING)
**Files:** 
- `hosts/storage/services/ntfy.nix` - ntfy server configuration
- `hosts/router/ntfy-webhook.nix` - webhook proxy for Alertmanager alerts

#### Ntfy Server Configuration
```nix
# Listen on port 2586, behind Caddy reverse proxy
services.ntfy-sh = {
  enable = true;
  settings = {
    base-url = "https://ntfy.arsfeld.one";
    upstream-base-url = "https://ntfy.sh";
    listen-http = ":2586";
    behind-proxy = true;
    message-size-limit = "8k";
  };
};
```

#### Sending Notifications (Alert Pattern from ntfy-webhook.nix)
```python
# HTTP POST to ntfy URL with headers
headers = {
    'Title': title,
    'Priority': priority,
    'Tags': tags,
}

req = urllib.request.Request(
    NTFY_URL,
    data=message.encode('utf-8'),
    headers=headers
)

urllib.request.urlopen(req)
```

#### Key Headers for Messages
- `Title` - Message title
- `Priority` - 1-5 (2=low, 4=warning, 5=critical)
- `Tags` - Emoji tags like `rotating_light`, `warning`, `white_check_mark`

#### Shell Equivalent (for systemd oneshots)
```bash
curl -d "message body" \
  -H "Title: Update Available" \
  -H "Priority: 3" \
  -H "Tags: rotating_light" \
  https://ntfy.arsfeld.one/containers-topic
```

#### ntfy Webhook Service Pattern (from router)
- Service type: `simple` with Python HTTP server
- `Restart = "always"` with `RestartSec = "10s"`
- Port: 9095
- User/group isolation
- Security: ProtectSystem, ProtectHome, NoNewPrivileges

---

### 4. Systemd Timer Patterns (EXISTING)
**Source:** Multiple modules - tablet-sync, media-sync, email, podman-image-pull, check-stock, supabase-maintenance, rustic

#### Standard Timer + Service Pattern
```nix
systemd.timers."service-name" = {
  wantedBy = ["timers.target"];
  timerConfig = {
    OnCalendar = "daily";  # or "hourly", "*/5 * * * *", etc.
    Persistent = true;      # Run missed timers if system was off
  };
};

systemd.services."service-name" = {
  description = "Service description";
  script = ''
    # shell script here
  '';
  serviceConfig = {
    Type = "oneshot";
    User = "root";  # or specific user
  };
  # Optional: specify dependencies
  wants = ["podman.service"];
  after = ["podman.service"];
};
```

#### Timer Scheduling Formats
- `"daily"` - Every day
- `"hourly"` - Every hour
- `"*-*-* 09:00:00"` - Specific time
- Persistent flag: Re-runs missed timers if system was down

#### Service Types for Timers
- `Type = "oneshot"` - Script runs to completion once
- Essential for timer-triggered tasks
- Exit code matters (non-zero = failure)

---

### 5. Service Restart Pattern (mkService Helper)
**File:** `modules/media/__mkService.nix`

#### mkService Architecture
```nix
mkService "mydia" {
  port = 4000;
  image = "ghcr.io/getmydia/mydia:master";
  container = { /* config */ };
  bypassAuth = true;
  tailscaleExposed = true;
}
```

#### What mkService Does
1. Accepts name + config options
2. Populates `media.containers.${name}` if container provided
3. Populates `media.gateway.services.${name}` for reverse proxy
4. Supports optional flags: `watchImage`, `bypassAuth`, `funnel`, `insecureTls`, `tailscaleExposed`

#### Restarting Containers (via systemd)
```nix
# Auto-generated by podman module
systemd.services."podman-${name}" = {
  # ...
};

# Restart via systemctl
systemctl restart "podman-${name}"
```

#### Container Metadata
- Container definition lives in `virtualisation.oci-containers.containers`
- Auto-generated systemd service: `podman-${name}`
- Service IP/hostname: accessible via `localhost:${exposedPort}`

---

### 6. Media Container Integration (Dependency Pattern)
**File:** `modules/media/containers.nix` (lines 201-212)

#### Storage Mount Dependencies
```nix
# For containers with mediaVolumes = true
systemd.services."podman-${name}" = {
  after = ["mnt-storage.mount"];
  requires = ["mnt-storage.mount"];
};
```

#### Volume Mounts
- `${configDir}/${name}:${configDir}` - Service config (created with tmpfiles.rules)
- `${dataDir}/files:/files` - File storage
- `${storageDir}/media:/media` - Media library (only on storage host)

#### Default Environment Variables
```nix
PUID = "5000";    # User ID (all media services)
PGID = "5000";    # Group ID
TZ = "UTC";       # Timezone (from config.media.config)
```

---

## Critical Patterns to Apply

### Pattern 1: Per-Service Polling Timer
```nix
systemd.timers."image-watch-${serviceName}" = {
  wantedBy = ["timers.target"];
  timerConfig = {
    OnBootSec = "2min";    # Start 2 min after boot
    OnUnitActiveSec = "5min"; # Then every 5 minutes
    Persistent = true;
  };
};

systemd.services."image-watch-${serviceName}" = {
  description = "Watch for image updates: ${serviceName}";
  script = ''
    # Registry polling logic here
  '';
  serviceConfig = {
    Type = "oneshot";
    User = "root";
  };
};
```

### Pattern 2: Image Digest Comparison (Reusable)
The existing daily pull pattern already does this - can be extracted:
1. Get current: `podman inspect container-name -f '{{.Image}}'`
2. Pull: `podman pull image-name`
3. Get new: `podman inspect image-name -f '{{.Id}}'`
4. Compare hashes
5. Restart if changed: `systemctl restart podman-container-name`

### Pattern 3: Ntfy Notification from Shell
```bash
# Send notification from systemd oneshot service
curl -d "Service updated and restarted" \
  -H "Title: ${serviceName} Updated" \
  -H "Priority: 3" \
  -H "Tags: rotating_light" \
  https://ntfy.arsfeld.one/container-updates
```

### Pattern 4: Opt-In Flag for mkService
The brainstorm identified this should be added:
```nix
mkService "finance-tracker" {
  port = 4000;
  image = "ghcr.io/arsfeld/finance-tracker:latest";
  watchImage = true;  # <-- NEW FLAG
  container = { /* ... */ };
}
```

---

## Constraints & Dependencies

### Must-Have
- Podman (not Docker) - storage host uses Podman
- Reuse digest comparison from `podman-image-pull` pattern
- ntfy is already configured - use existing infrastructure
- Must not interfere with daily `podman-image-pull` timer

### Nice-to-Have
- Per-service debug logs for troubleshooting
- Coexist peacefully with daily pull (independent timers)
- Avoid cascade failures (one service pull failure doesn't block others)

---

## Implementation Readiness

### Ready to Build
- systemd timer syntax is well-established in codebase
- Podman image polling logic exists and works
- ntfy infrastructure is live and proven
- mkService pattern is established and flexible

### Open Questions
None identified in brainstorm - all design decisions resolved.

### Gotchas to Watch
1. **Shell escaping** - Image digests with special chars; use proper quoting
2. **Podman availability** - Ensure podman service is up before polling (add wait logic)
3. **Rate limiting** - GHCR may rate limit; test with 5-min polling for 2-3 images first
4. **ntfy failures** - Don't fail service restart if notification fails; wrap in error handling
5. **Container restart timing** - Brief downtime expected; may impact active users

---

## Files to Reference

**Core Implementation Patterns:**
- `/home/arosenfeld/Code/nixos/modules/constellation/podman.nix` - Daily pull + restart logic
- `/home/arosenfeld/Code/nixos/modules/media/__mkService.nix` - Service declaration helper
- `/home/arosenfeld/Code/nixos/modules/media/containers.nix` - Container integration

**Notification Pattern:**
- `/home/arosenfeld/Code/nixos/hosts/router/ntfy-webhook.nix` - ntfy HTTP posting (Python example, curl equiv exists)

**Configuration References:**
- `/home/arosenfeld/Code/nixos/hosts/storage/services/ntfy.nix` - ntfy server setup
- `/home/arosenfeld/Code/nixos/modules/services/media-apps.nix` - mkService usage example (finance-tracker, mydia)

**Brainstorm (Source of Truth):**
- `/home/arosenfeld/Code/nixos/docs/brainstorms/2026-03-24-container-image-watcher-brainstorm.md`

