# Brainstorm: Add Bitmagnet to Storage

**Date:** 2026-04-01
**Status:** Complete

## What We're Building

Add [Bitmagnet](https://bitmagnet.io) to the storage host as a self-hosted BitTorrent DHT crawler, torrent indexer, and search engine. Bitmagnet crawls the BitTorrent DHT network directly to discover torrents and classifies content (movies, TV shows) using TMDB metadata. It exposes a Torznab-compatible endpoint for integration with the existing *arr stack via Prowlarr.

### Core Requirements

- Run Bitmagnet as a Podman container on storage
- Use the existing shared PostgreSQL instance (create a `bitmagnet` database)
- Integrate with Prowlarr via Torznab endpoint for Sonarr/Radarr search
- Use a personal TMDB API key (stored in sops) for content classification
- Expose via gateway at `bitmagnet.arsfeld.one` (Authelia auth) and `bitmagnet.bat-boa.ts.net` (Tailscale)
- No VPN — direct DHT connection is acceptable

## Why This Approach

### Containerized via `media.containers`

Bitmagnet will use the `media.containers` pattern — the simplest and most consistent way to add services on storage. This handles gateway registration, volume creation, and tmpfiles rules automatically.

There's an existing disabled native NixOS module reference in `hosts/storage/services/media.nix`, but the container approach is more flexible and matches how most services are deployed on storage.

### Shared PostgreSQL

Bitmagnet will share the existing PostgreSQL instance rather than running a dedicated container. This is simpler and avoids resource duplication. A dedicated `bitmagnet` database will be created. Note: the DHT crawler database can grow to tens of GB over time — monitor disk usage.

### Prowlarr Integration

Bitmagnet's Torznab endpoint (`http://bitmagnet:3333/torznab`) will be added to Prowlarr as a Generic Torznab indexer. No API key is needed. Prowlarr will sync it to Sonarr, Radarr, and other connected apps automatically.

## Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Deployment method | `media.containers` | Consistent with other storage services, handles gateway/volumes automatically |
| Database | Shared PostgreSQL | Already running on storage, simpler than a dedicated container |
| VPN | No VPN | Acceptable risk for DHT crawling |
| TMDB API key | Personal key via sops | Better rate limits than shared default key |
| Access | Authelia + Tailscale | Standard pattern: `bitmagnet.arsfeld.one` + `bitmagnet.bat-boa.ts.net` |
| Auth bypass | Yes | Bitmagnet has no built-in auth; Authelia handles it at the gateway level |
| Prowlarr integration | Yes | Primary use case for *arr stack search |

## Technical Details

### Ports

- **3333** — HTTP API / Web UI / Torznab endpoint (exposed via gateway)
- **3334** (TCP+UDP) — BitTorrent DHT protocol (needs host port mapping)

### Container Image

`ghcr.io/bitmagnet-io/bitmagnet:latest`

### Container Command

```
worker run --keys=http_server --keys=queue_server --keys=dht_crawler
```

### Environment Variables

| Variable | Source | Value |
|----------|--------|-------|
| `POSTGRES_HOST` | hardcoded | `host.containers.internal` (access host PostgreSQL from container) |
| `POSTGRES_PASSWORD` | sops secret | From `bitmagnet-env` secret |
| `POSTGRES_DB` | hardcoded | `bitmagnet` |
| `PGUSER` | hardcoded | `bitmagnet` |
| `TMDB_API_KEY` | sops secret | Personal TMDB key |

### PostgreSQL Setup

- Create a `bitmagnet` PostgreSQL user and database on the existing instance
- Add to `hosts/storage/services/db.nix` database/user declarations

### Files to Create/Modify

1. **Create** `hosts/storage/services/bitmagnet.nix` — container + gateway + secrets
2. **Modify** `hosts/storage/services/default.nix` — add import
3. **Modify** `hosts/storage/services/db.nix` — add bitmagnet database/user
4. **Modify** `secrets/sops/storage.yaml` — add `bitmagnet-env` secret (POSTGRES_PASSWORD, TMDB_API_KEY)

## Open Questions

_None — all questions resolved during brainstorming._
