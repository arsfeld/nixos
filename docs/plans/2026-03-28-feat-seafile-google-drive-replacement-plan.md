---
title: "feat: Deploy Seafile as Lightweight Google Drive Replacement"
type: feat
status: active
date: 2026-03-28
origin: docs/brainstorms/2026-03-28-seafile-google-drive-replacement-brainstorm.md
---

# feat: Deploy Seafile as Lightweight Google Drive Replacement

## Overview

Deploy Seafile CE (Community Edition) as a self-hosted file sync and sharing service on the **storage** host, with a headless sync client on **raider**. This replaces Nextcloud's file management role with a purpose-built, lightweight alternative.

Key decisions carried forward from brainstorm:
- Seafile chosen over OpenCloud (maturity) and Syncthing+Filebrowser (unified UX)
- Data at `/mnt/storage/data/Seafile` (large storage volume)
- Gateway at `seafile.arsfeld.one` with `bypassAuth = true`
- Home Manager systemd user service for `seaf-cli` on raider
- Manual migration from Nextcloud (no scripted bulk import)

**Corrections from brainstorm** (discovered during research):
- **Container deployment**, not native NixOS service — `services.seafile` does not exist in nixpkgs
- **MariaDB**, not SQLite — official Docker image (`seafileltd/seafile-mc`) requires MariaDB since v11.0. MariaDB already runs on storage.
- **Single-port proxy** — the Docker image bundles an internal Nginx that consolidates ports 8000 (Seahub) and 8082 (file server) behind port 80

## Proposed Solution

### Server (storage host)

Deploy `seafileltd/seafile-mc:13.0-latest` as a Podman container via the existing `media.containers` system. The container connects to the existing MariaDB instance on storage for its three databases (`ccnet_db`, `seafile_db`, `seahub_db`).

```
                    storage host
┌────────────────────────────────────────────┐
│                                            │
│  Caddy (*.arsfeld.one)                     │
│    └─► seafile container :80               │
│          ├─ internal nginx                 │
│          ├─ seahub (web UI)                │
│          ├─ seafile-server (file sync)     │
│          └─► MariaDB (existing, :3306)     │
│                                            │
│  Data: /mnt/storage/data/Seafile → /shared │
│  Config: /var/data/seafile → /shared       │
│                                            │
└────────────────────────────────────────────┘
```

### Client (raider desktop)

`seaf-cli` from `seafile-shared` (v9.0.15, available in nixpkgs) runs as a Home Manager systemd user service. Syncs libraries to `~/Seafile/`.

```
                    raider
┌─────────────────────────────────┐
│  systemd user service           │
│    seaf-cli daemon              │
│    syncs ~/Seafile/ ◄──► server │
│                                 │
│  Browser → seafile.arsfeld.one  │
└─────────────────────────────────┘
```

## Technical Considerations

### MariaDB Integration

Storage already runs MariaDB (`hosts/storage/services/db.nix`). Seafile needs three databases:
- `ccnet_db`, `seafile_db`, `seahub_db`
- A `seafile` MariaDB user with full privileges on these databases

These can be added to the existing `services.mysql.ensureDatabases` and `ensureUsers`.

### Container Networking

The Seafile container needs to reach MariaDB on the host. Options:
- **Host network mode** — simplest, container sees `127.0.0.1:3306` directly
- **`host.containers.internal`** — Podman's host gateway (used by romm for PostgreSQL)

Host network mode is simplest since the container only exposes port 80 and needs to reach MariaDB.

### Caddy Proxy

The official Docker image bundles an internal Nginx that routes requests to the correct backend (Seahub on 8000, file server on 8082). Caddy only needs to proxy to port 80 — no path-based routing needed. Standard `media.gateway.services` registration works.

### Data Layout

Following the OpenCloud pattern (split config/data):
- **Config + data volume**: `/mnt/storage/data/Seafile:/shared` — Seafile stores everything under `/shared` inside the container (config, logs, block storage)
- The container manages its own directory structure under `/shared`

### Backup

`/mnt/storage/data/Seafile` is automatically included in the `hetzner` restic backup profile (backs up all of `/mnt/storage`, excludes only `backups/`, `media/`, `legacy/`). MariaDB databases are not currently backed up via `mysqldump` — a pre-backup dump should be added.

### Client Bootstrap (Manual)

After deploying the server and raider config, one-time manual setup is required:

```bash
# On raider, after deploying the Home Manager config:
seaf-cli init -d ~/seafile-client
seaf-cli start
seaf-cli sync -l <library-id> -s https://seafile.arsfeld.one -d ~/Seafile -u <email> -p <password>
```

The token persists in `~/.ccnet/` across restarts. The systemd service handles `seaf-cli start`/`stop`.

## Acceptance Criteria

- [x] Seafile container running on storage with web UI accessible at `seafile.arsfeld.one`
- [x] Admin account created and functional
- [x] MariaDB databases provisioned (`ccnet_db`, `seafile_db`, `seahub_db`)
- [ ] File upload/download works via web UI
- [ ] `seaf-cli` daemon running on raider via Home Manager systemd service
- [ ] At least one library syncing between server and raider's `~/Seafile/`
- [x] Tailscale exposure at `seafile.bat-boa.ts.net` (optional, nice to have)
- [x] Seafile data included in existing backup schedule

## Implementation Phases

### Phase 1: MariaDB Setup

Add Seafile databases and user to existing MariaDB config.

**File: `hosts/storage/services/db.nix`**

```nix
# Add to services.mysql.ensureUsers:
{
  name = "seafile";
  ensurePermissions = {
    "ccnet_db.*" = "ALL PRIVILEGES";
    "seafile_db.*" = "ALL PRIVILEGES";
    "seahub_db.*" = "ALL PRIVILEGES";
  };
}

# Add to services.mysql.ensureDatabases:
"ccnet_db"
"seafile_db"
"seahub_db"
```

### Phase 2: Secrets

Create sops secrets for Seafile admin credentials, JWT key, and MariaDB passwords.

**File: `secrets/sops/storage.yaml`**

Add entries:
- `seafile-admin-email`
- `seafile-admin-password`
- `seafile-jwt-key` (random 32+ char string)
- `seafile-mysql-password`
- `seafile-mysql-root-password`

**File: `hosts/storage/services/seafile.nix`** (sops declarations)

```nix
sops.secrets.seafile-env = {
  sopsFile = ../../../secrets/sops/storage.yaml;
  # Contains SEAFILE_MYSQL_DB_PASSWORD, INIT_SEAFILE_ADMIN_EMAIL, etc.
};
```

### Phase 3: Container Deployment

Create the Seafile service file using the existing container patterns.

**File: `hosts/storage/services/seafile.nix`**

```nix
{ config, lib, ... }:
let
  vars = config.media.config;
  dataDir = "/mnt/storage/data/Seafile";
in {
  # Gateway registration
  media.gateway.services.seafile = {
    port = 10080;  # Host port mapped to container's port 80
    settings.bypassAuth = true;
    exposeViaTailscale = true;
  };

  # Directory creation
  systemd.tmpfiles.rules = [
    "d ${dataDir} 0750 ${vars.user} ${vars.group} -"
  ];

  # Container
  virtualisation.oci-containers.containers.seafile = {
    image = "seafileltd/seafile-mc:13.0-latest";
    environment = {
      SEAFILE_SERVER_HOSTNAME = "seafile.arsfeld.one";
      SEAFILE_SERVER_PROTOCOL = "https";
      TIME_ZONE = "America/Toronto";
      SEAFILE_MYSQL_DB_HOST = "host.containers.internal";
      NON_ROOT = "false";
    };
    environmentFiles = [
      config.sops.secrets.seafile-env.path
    ];
    volumes = [
      "${dataDir}:/shared"
    ];
    ports = ["10080:80"];
    extraOptions = [
      "--add-host=host.containers.internal:host-gateway"
    ];
  };

  # Ensure container starts after MariaDB
  systemd.services.podman-seafile = {
    after = ["mysql.service"];
    requires = ["mysql.service"];
  };
}
```

**File: `hosts/storage/services/default.nix`** — add `./seafile.nix` to imports.

### Phase 4: Home Manager Client (Raider)

Add `seaf-cli` daemon as a systemd user service.

**File: `home/home.nix`**

```nix
# Add seafile-shared to packages
home.packages = with pkgs; [
  # ... existing packages ...
  seafile-shared
];

# Systemd user service for seaf-cli
systemd.user.services.seafile-cli = lib.mkIf stdenv.isLinux {
  Unit = {
    Description = "Seafile CLI sync daemon";
    After = ["network-online.target"];
  };
  Service = {
    Type = "forking";
    ExecStartPre = "${pkgs.coreutils}/bin/mkdir -p %h/Seafile %h/seafile-client";
    ExecStart = "${pkgs.seafile-shared}/bin/seaf-cli start";
    ExecStop = "${pkgs.seafile-shared}/bin/seaf-cli stop";
    Restart = "on-failure";
    RestartSec = 10;
  };
  Install = {
    WantedBy = ["default.target"];
  };
};
```

### Phase 5: MariaDB Backup

Add mysqldump to the backup pipeline to ensure consistent database backups.

**File: `hosts/storage/services/db.nix`** or a new backup hook

```nix
# Add a systemd service/timer for mysqldump before restic runs
# This ensures Seafile's MariaDB data is consistently backed up
services.mysqlBackup = {
  enable = true;
  databases = config.services.mysql.ensureDatabases;
  calendar = "daily";
  location = "/var/backup/mysql";
};
```

## Alternative Approaches Considered

1. **Native NixOS service** — No `services.seafile` module exists in nixpkgs. Would require packaging the server from source. Rejected as too much effort for a personal deployment.

2. **SQLite database** — Not supported by the official Docker image since Seafile 11.0. Third-party images exist but are unmaintained. Rejected for reliability.

3. **OpenCloud (already deployed)** — Newer ecosystem, less mature desktop client. Already running but not being used for file sync. Could revisit if Seafile doesn't work out.

4. **Syncthing + Filebrowser** — Already running. No unified drive experience, no file versioning. Remains available as fallback.

## Dependencies & Risks

| Risk | Impact | Mitigation |
|------|--------|------------|
| Seafile Docker image upgrade breaks config | Service downtime | Pin to specific version tag (e.g., `13.0.19`), test upgrades in advance |
| MariaDB schema changes between versions | Data corruption | MariaDB backup before upgrades, test with `--dry-run` |
| `seaf-cli` version mismatch with server | Sync failures | nixpkgs `seafile-shared` is v9.0.15, server is v13 — verify compatibility |
| Block storage format is opaque | Can't browse files on disk | Accept this trade-off; use web UI or sync client for access |
| First-time client setup is manual | Minor UX friction | Document bootstrap steps clearly |

## Deferred Decisions

(from brainstorm)

1. **Nextcloud fate** — Keep for PIM or remove entirely. Decide after using Seafile for a few weeks.
2. **Mobile access** — Seafile mobile apps vs web UI. Focus on server + desktop first.
3. **Funnel exposure** — Whether to make Seafile publicly accessible via Tailscale Funnel.

## Sources & References

### Origin

- **Brainstorm document:** [docs/brainstorms/2026-03-28-seafile-google-drive-replacement-brainstorm.md](docs/brainstorms/2026-03-28-seafile-google-drive-replacement-brainstorm.md) — Key decisions: Seafile over alternatives, data at `/mnt/storage/data/Seafile`, `bypassAuth`, manual migration

### Internal References

- `hosts/storage/services/db.nix` — Existing MariaDB + PostgreSQL setup
- `hosts/storage/services/files.nix` — Nextcloud config (reference for native service + gateway pattern)
- `modules/constellation/opencloud.nix` — Constellation module pattern reference
- `home/home.nix:519-536` — rclone FUSE mount (Home Manager systemd service pattern)
- `hosts/storage/services/misc.nix` — Container service examples (filebrowser, romm)
- `modules/media/containers.nix` — Container orchestration system
- `modules/media/gateway.nix` — Caddy gateway system

### External References

- [Seafile CE Docker Setup (v13)](https://manual.seafile.com/13.0/setup/setup_ce_by_docker/) — Official deployment guide
- [seafileltd/seafile-mc on Docker Hub](https://hub.docker.com/r/seafileltd/seafile-mc/) — Container image (13.0.19)
- [seaf-cli documentation](https://help.seafile.com/syncing_client/linux-cli/) — Headless sync client
- [Seafile environment variables](https://manual.seafile.com/latest/config/env/) — Container configuration
