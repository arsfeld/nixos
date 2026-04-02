---
title: "feat: Add Bitmagnet DHT Crawler to Storage"
type: feat
status: active
date: 2026-04-01
origin: docs/brainstorms/2026-04-01-bitmagnet-storage-brainstorm.md
---

# feat: Add Bitmagnet DHT Crawler to Storage

## Overview

Add [Bitmagnet](https://bitmagnet.io) as a containerized service on the storage host. Bitmagnet is a self-hosted BitTorrent DHT crawler, torrent indexer, and search engine that provides a Torznab-compatible endpoint for integration with the existing *arr stack via Prowlarr.

## Proposed Solution

Use the `media.containers` module for the container definition (automatic gateway, tmpfiles, port mapping), supplemented with a separate `virtualisation.oci-containers.containers.bitmagnet.cmd` declaration for the custom command (the module system merges them). DHT port 3334 and `--add-host` are handled via `extraOptions`.

PostgreSQL uses `trust` authentication from the Podman network (like openarchiver), avoiding the need for a password-setup service.

(see brainstorm: `docs/brainstorms/2026-04-01-bitmagnet-storage-brainstorm.md`)

## Technical Considerations

- **`media.containers` lacks a `cmd` option** — set `virtualisation.oci-containers.containers.bitmagnet.cmd` separately; the NixOS module system merges both declarations into one container definition
- **DHT port 3334 (TCP+UDP)** — `media.containers` only maps one TCP port (3333 for the web UI); add DHT port via `extraOptions` with `--publish=3334:3334/tcp` and `--publish=3334:3334/udp`
- **Host PostgreSQL access** — add `--add-host=host.containers.internal:host-gateway` via `extraOptions` so the container can reach the host's PostgreSQL on `10.88.0.1:5432`
- **Auth** — `bypassAuth = false` (Authelia protects the web UI). Prowlarr connects via `localhost:3333`, bypassing Caddy/Authelia entirely. No API bypass rules needed.
- **PUID/PGID** — injected automatically by `media.containers` but ignored by Bitmagnet (not a LinuxServer.io image). Harmless.
- **Database growth** — DHT crawler DB can grow to tens of GB. Included in `ensureDatabases` so it gets automatic backups. Monitor disk usage over time.
- **Schema migration** — Bitmagnet auto-creates/migrates its schema on startup. No manual migration step needed.
- **Startup ordering** — add `systemd.services.podman-bitmagnet.after/requires = ["postgresql.service"]` to ensure PostgreSQL is ready

## Acceptance Criteria

- [ ] Bitmagnet container runs on storage and is healthy
- [ ] DHT crawler is active (check logs for peer discovery)
- [ ] Web UI accessible at `bitmagnet.arsfeld.one` (behind Authelia)
- [ ] Web UI accessible at `bitmagnet.bat-boa.ts.net` (Tailscale)
- [ ] Torznab endpoint works: `curl http://localhost:3333/torznab` returns XML
- [ ] Prowlarr can add Bitmagnet as a Generic Torznab indexer
- [ ] TMDB classification is working (torrents get movie/TV metadata)
- [x] PostgreSQL `bitmagnet` database exists and is included in backups
- [x] Disabled `services.bitmagnet` block removed from `media.nix`

## Implementation

### Step 1: Add sops secrets

Edit `secrets/sops/storage.yaml` to add `bitmagnet-env` containing:

```
TMDB_API_KEY=<your-tmdb-key>
```

No `POSTGRES_PASSWORD` needed since we use `trust` auth from the Podman network.

```bash
nix develop -c sops secrets/sops/storage.yaml
```

### Step 2: Add PostgreSQL database and user

Modify `hosts/storage/services/db.nix`:

```nix
# In services.postgresql.ensureUsers, add:
{
  name = "bitmagnet";
  ensureDBOwnership = true;
}

# In services.postgresql.ensureDatabases, add:
"bitmagnet"

# In services.postgresql.authentication, add:
host bitmagnet bitmagnet 10.88.0.0/16 trust
```

### Step 3: Create `hosts/storage/services/bitmagnet.nix`

```nix
{
  config,
  pkgs,
  lib,
  ...
}: let
  vars = config.media.config;
  httpPort = 3333;
  dhtPort = 3334;
in {
  sops.secrets."bitmagnet-env" = {};

  media.containers.bitmagnet = {
    image = "ghcr.io/bitmagnet-io/bitmagnet:latest";
    listenPort = httpPort;
    exposePort = httpPort;
    environmentFiles = [
      config.sops.secrets."bitmagnet-env".path
    ];
    environment = {
      POSTGRES_HOST = "host.containers.internal";
      POSTGRES_DB = "bitmagnet";
      PGUSER = "bitmagnet";
    };
    extraOptions = [
      "--add-host=host.containers.internal:host-gateway"
      "--publish=${toString dhtPort}:${toString dhtPort}/tcp"
      "--publish=${toString dhtPort}:${toString dhtPort}/udp"
    ];
  };

  # media.containers has no cmd option; set it separately (module system merges)
  virtualisation.oci-containers.containers.bitmagnet.cmd = [
    "worker"
    "run"
    "--keys=http_server"
    "--keys=queue_server"
    "--keys=dht_crawler"
  ];

  # Ensure PostgreSQL is ready before starting bitmagnet
  systemd.services.podman-bitmagnet = {
    after = ["postgresql.service"];
    requires = ["postgresql.service"];
  };

  media.gateway.services.bitmagnet.exposeViaTailscale = true;
}
```

### Step 4: Add import to `hosts/storage/services/default.nix`

Add `./bitmagnet.nix` to the imports list (alphabetically, between `./auth.nix` and `./cloud-sync.nix`).

### Step 5: Remove disabled bitmagnet from `hosts/storage/services/media.nix`

Remove lines 60-65 (the disabled `services.bitmagnet` block and commented-out age secret references).

### Step 6: Build and deploy

```bash
nix build .#nixosConfigurations.storage.config.system.build.toplevel
just deploy storage
```

### Step 7: Post-deploy — add Prowlarr indexer

1. Open Prowlarr UI
2. Add Indexer -> Generic Torznab
3. URL: `http://localhost:3333/torznab`
4. No API key needed
5. Test and save — Prowlarr syncs to Sonarr/Radarr automatically

## Files Changed

| File | Action | Purpose |
|------|--------|---------|
| `hosts/storage/services/bitmagnet.nix` | Create | Container, gateway, secrets, systemd ordering |
| `hosts/storage/services/default.nix` | Modify | Add import |
| `hosts/storage/services/db.nix` | Modify | Add PostgreSQL user, database, and pg_hba rule |
| `hosts/storage/services/media.nix` | Modify | Remove disabled `services.bitmagnet` block |
| `secrets/sops/storage.yaml` | Modify | Add `bitmagnet-env` secret |

## Sources & References

- **Origin brainstorm:** [docs/brainstorms/2026-04-01-bitmagnet-storage-brainstorm.md](docs/brainstorms/2026-04-01-bitmagnet-storage-brainstorm.md) — key decisions: `media.containers` pattern, shared PostgreSQL, no VPN, Authelia + Tailscale access, Prowlarr integration
- Similar service: `hosts/storage/services/yarr.nix` (cleanest `media.containers` example)
- Host DB access pattern: `hosts/storage/services/seafile.nix` (`--add-host` usage)
- PostgreSQL trust auth pattern: `hosts/storage/services/db.nix:102-103` (openarchiver)
- Container module options: `modules/media/containers.nix:48-189`
- [Bitmagnet installation docs](https://bitmagnet.io/setup/installation.html)
- [Bitmagnet Servarr integration](https://bitmagnet.io/guides/servarr-integration.html)
