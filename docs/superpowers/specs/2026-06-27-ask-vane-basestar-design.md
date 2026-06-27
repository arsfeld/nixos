# ask.arsfeld.one — AI search on basestar (Morphic + Open WebUI), podman migration

**Date:** 2026-06-27
**Status:** Implemented & deployed
**Scope:** Stand up AI web-search ("ask") on basestar while galactica is down, as a
Morphic vs Open WebUI A/B; and migrate basestar's container backend docker→podman.

> This document was updated to match the **as-built** architecture. The decision
> trail below records why the design changed during implementation.

## Outcome (as built)

- **`ask.arsfeld.one` → Morphic** (`ghcr.io/miurla/morphic:latest`), on **DeepSeek V4**
  via OpenRouter, using the host's **system PostgreSQL** (`morphic` DB) for state.
- **`webui.arsfeld.one` → Open WebUI** (`ghcr.io/open-webui/open-webui:main`), DeepSeek V4
  via OpenRouter, with **SearXNG web search + reranking**.
- **Native SearXNG** on basestar (port 8888) shared by both; also `search.arsfeld.one`.
- **basestar migrated from docker to podman** (`constellation.podman.enable`).
- All services declared via `mkService`. No per-app firewall rules.

## Decision trail (why it ended here)

1. **Vane (Perplexica successor) rejected.** It was the previous `ask` engine on
   galactica, but upstream is frozen (no commits since 2026-04-11 = `:latest`) and its
   OpenRouter streaming tool-call parser crashes (`Error:  is empty`) on *every*
   OpenRouter model — unmerged fix PR #1151. Abandoned + broken.
2. **Morphic vs Open WebUI A/B.** Morphic is the truest Perplexity UX but has **no
   reranking** (mixed retrieval quality in prior use); Open WebUI is the most-maintained
   option that does SearXNG + reranking + OpenRouter on arm64. Run both, keep the winner.
   Khoj evaluated but heavier (Django/Postgres/Redis); not selected.
3. **Model: DeepSeek V4 Flash** (`deepseek/deepseek-v4-flash`, 1M ctx, tool use,
   ~$0.09/$0.18 per M) as default; `deepseek/deepseek-v4-pro` for hard queries. One
   OpenRouter key drives chat + (for Open WebUI) embeddings.
4. **docker → podman.** The initial docker implementation hit a hard wall: Docker 29 +
   the NixOS nftables firewall conflict — every nftables reload (each deploy) flushed
   docker's NAT chains, so new containers couldn't start and existing bridge containers
   lost outbound. Podman/netavark uses nftables natively and survives reloads (galactica
   already runs this exact stack on podman). Migrating fixed the root cause.
5. **System postgres, no Redis.** Morphic's DB uses the host's existing system
   PostgreSQL (the `planka.nix` pattern) rather than a containerized one. Redis is
   optional for Morphic (chat-history only) and was dropped to keep it simple.

## Routing (works with galactica down)

- basestar's cloudflared shares galactica's tunnel UUID (connector redundancy), so
  `*.arsfeld.one` is served by basestar while galactica is down.
- `media.gateway.enable` + `media.config.domain = "arsfeld.one"` → Caddy serves the
  `ask`/`webui`/`search` vhosts on `https://localhost`, the tunnel's ingress target.
- Authelia is on galactica (down) → both apps use `bypassAuth = true`; auth is enforced
  at the **Cloudflare Zero Trust** edge (a dashboard action, like `chat`).

```
ask.arsfeld.one   ─┐
webui.arsfeld.one ─┼─ cloudflared (shared tunnel) ─▶ Caddy gateway (localhost)
search.arsfeld.one ┘                                      │
                            ┌────────────────────────────┼───────────────┐
                            ▼                             ▼               ▼
                     Morphic (podman :3000)      Open WebUI (podman :8080)  SearXNG
                            │   │                        │                 (native :8888)
              OpenRouter ◀──┘   │ host.containers.internal:5432            ▲
              (DeepSeek V4)      ▼                        └── host.containers.internal:8888
                         system PostgreSQL (morphic DB)
```

## Components (all via `mkService`; podman backend)

### SearXNG (native, shared) — `hosts/basestar/services/search.nix`
Copy of galactica's `search.nix`: `mkService "search"` (port 8888, `tailscaleExposed`),
`services.searx` (uwsgi + redisCreateLocally) on nixpkgs-unstable `searxng` rebuilt
against stable python3; `searxng-env` sops secret (`SEARXNG_SECRET_KEY`). Engine tuning:
bing on; brave/startpage/wikidata/mojeek off; `formats = ["html" "json"]`.

### Morphic → ask.arsfeld.one — `hosts/basestar/services/ask.nix`
`mkService "ask"` (port 3000, `bypassAuth`, `tailscaleExposed`, `watchImage`,
`configDir = null`), env from the `morphic-env` sops secret. Reaches the host's postgres
and SearXNG via **`host.containers.internal`** (podman provides it automatically — no
`--add-host`). Plus host-level config in the same file:
- System PostgreSQL: `ensureDatabases`/`ensureUsers` for `morphic`, a pg_hba entry
  `host morphic morphic 10.88.0.0/16 scram-sha-256` (podman subnet), and a postStart
  `ALTER USER` reading the `morphic-db-password` sops secret (owner postgres).
- `systemd.services."${backend}-ask"` ordered `after`/`wants` `postgresql.service`.

### Open WebUI → webui.arsfeld.one — `hosts/basestar/services/webui.nix`
`mkService "webui"` (port 8080, `bypassAuth`, `tailscaleExposed`, `watchImage`,
`configDir = "/app/backend/data"` → `/var/data/webui`), env from `open-webui-env` secret +
`OPENAI_API_BASE_URL` (OpenRouter), `ENABLE_WEB_SEARCH`/`WEB_SEARCH_ENGINE=searxng`/
`SEARXNG_QUERY_URL=http://host.containers.internal:8888/search?q=<query>`, and
`ENABLE_RAG_HYBRID_SEARCH` + `RAG_RERANKING_MODEL=BAAI/bge-reranker-v2-m3` (local CPU).

### Backend migration (host) — `hosts/basestar/configuration.nix`
- `constellation.podman.enable = true` (was `constellation.docker.enable`); sets oci
  backend = podman, docker-socket compat for the Forgejo runner.
- `networking.firewall.trustedInterfaces = ["podman0"]` so containers reach host
  services via the podman bridge. Host firewall (22/80/443 + fail2ban) and the OCI cloud
  firewall still gate external access. **No per-app firewall rules.**
- `planka.nix` / `siyuan.nix`: their hand-written `systemd.services.docker-<name>` units
  changed to `"${backend}-<name>"` (backend-aware) so they work under podman.

## Secrets (`secrets/sops/basestar.yaml`)
- `searxng-env` — `SEARXNG_SECRET_KEY`
- `morphic-env` — OpenRouter key + base URL/provider, `DATABASE_URL`
  (`…@host.containers.internal:5432/morphic`), `SEARXNG_API_URL`
  (`http://host.containers.internal:8888`), `SEARCH_API=searxng`, `ENABLE_AUTH=false`
- `morphic-db-password` — postgres role password (owner postgres)
- `open-webui-env` — `OPENAI_API_KEY` (OpenRouter), `WEBUI_SECRET_KEY`

## Data safety (verified)
All live app data is on host bind-mounts (`/var/data/sillytavern*`, `/var/data/yarr`,
`/var/data/finance-tracker`, `/var/lib/siyuan`, `/var/lib/planka`, postgres in
`/var/lib/postgresql`), so the docker→podman switch preserved everything — **SillyTavern
included**. The only docker named volumes were defunct (empty planka `/app/data`, an old
containerized-searxng volume, stale supabase config dirs); left in `/var/lib/docker`.

## Manual steps (outside this repo)
1. Cloudflare Zero Trust Access apps for `ask.arsfeld.one` + `webui.arsfeld.one`.
2. Morphic UI: select `deepseek/deepseek-v4-flash`.
3. Open WebUI: first sign-up = admin; confirm OpenRouter connection + DeepSeek model +
   SearXNG web search + reranking.

## Verification (done)
`just build basestar` + `just deploy basestar`; all containers up under podman
(`sudo podman ps`); SillyTavern data intact; Morphic migrations ran against system
postgres; Open WebUI → SearXNG returns JSON; `chat` outbound restored; public
`ask`/`webui`/`chat` all return HTTP 200.

## Out of scope
Migrating galactica's old Vane/Morphic data; Khoj; Cloudflare Access creation; cleaning
leftover `/var/lib/docker` images/volumes (safe to prune later to reclaim disk).
