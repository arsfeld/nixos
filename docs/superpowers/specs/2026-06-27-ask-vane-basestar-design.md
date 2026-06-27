# ask.arsfeld.one — AI search on basestar (Morphic + Open WebUI A/B)

**Date:** 2026-06-27
**Status:** Approved (pending spec review)
**Scope:** Permanently move AI web-search ("ask") from galactica (down) to
basestar, and stand up **two** maintained, reranking-capable engines side by
side so the better one can be chosen.

## Background & decision trail

`ask.arsfeld.one` previously ran **Vane** (Perplexica's successor) on galactica.
galactica is down. Research during design established:

- **Vane is out.** Its `master` branch has had no code commits since
  2026-04-11 (== `:latest` == v1.12.2) and its OpenRouter streaming tool-call
  parser crashes with `Error:  is empty` on empty argument deltas
  (`openaiLLM.ts`, `parse(existingCall.arguments)`). This breaks *every*
  OpenRouter model (confirmed on gpt-4o-mini in issue #1080, not DeepSeek-
  specific). The one-line fix is unmerged PR #1151. Running stock `:latest`
  would be broken; `watchImage` would re-break any hand patch. Abandoned +
  broken → rejected.
- **Morphic** is actively maintained (commits daily) and the truest Perplexity
  UX, but has **no embedding/reranking** stage — raw SearXNG results go to the
  model, which gave mixed retrieval quality in prior use.
- **Khoj** and **Open WebUI** both do real reranking + SearXNG + OpenRouter on
  arm64 (verified in source). Open WebUI is far more battle-tested (143k★,
  lighter single-container stack); Khoj is heavier (Django + Postgres + Redis).

**Chosen approach:** run **Morphic** (truest clone, but no reranking) and
**Open WebUI** (reranking + web search, most maintained) head-to-head, both on
DeepSeek V4 via OpenRouter, then keep the winner.

- `ask.arsfeld.one`   → **Morphic**
- `webui.arsfeld.one`  → **Open WebUI**
- (`ask` can later be repointed to the winner.)

## Routing — works with galactica down

- basestar's cloudflared runs on the **same tunnel UUID** as galactica
  (connector redundancy), so `*.arsfeld.one` is served by basestar while
  galactica is down.
- basestar has `media.gateway.enable = true`, `media.config.domain =
  "arsfeld.one"`, so the Caddy gateway serves `*.arsfeld.one` vhosts on
  `https://localhost` (the tunnel's ingress target).
- Authelia is on galactica (down) → both services use `bypassAuth = true` with
  auth enforced at the **Cloudflare Zero Trust** edge (mirrors `chat`).

```
ask.arsfeld.one   ─┐
webui.arsfeld.one ─┼─ cloudflared (shared tunnel) ─▶ Caddy gateway (localhost)
                   │                                      │
                   │                          ┌───────────┴────────────┐
                   ▼                          ▼                        ▼
            (edge: CF Access)          Morphic (:3000)          Open WebUI (:8080)
                                        │   │   │                 │        │
                          OpenRouter ◀──┘   │   │                 │        │ OpenRouter
                          (DeepSeek V4)      │   │                 │        │ (DeepSeek V4)
                              morphic-postgres│   │ morphic-redis   │ local reranker (CPU)
                              (sidecar, net=ask)  (sidecar)         │
                                                  │                 │
                                                  ▼                 ▼
                                      SearXNG (native NixOS, :8888) ◀┘
                                      (also search.arsfeld.one + tailnet)
```

## Components (all on basestar; **docker** backend; all via `mkService`)

### 1. SearXNG (native, shared)

Replicate galactica's `hosts/galactica/services/search.nix`:

- `mkService "search"` (`port = 8888`, `tailscaleExposed = true`) → also yields
  `search.arsfeld.one`.
- `services.searx` (uwsgi, `redisCreateLocally = true`), nixpkgs-unstable
  `searxng` override rebuilt against stable `python3`; same engine tuning
  (bing on; brave/startpage/wikidata/mojeek off; `formats = ["html" "json"]`).
- New sops secret `searxng-env` (`SEARXNG_SECRET_KEY`), owner `searx`.
- Reachable from containers via `host.docker.internal:8888`; open `8888` **only
  on the docker bridge interface** (`networking.firewall.interfaces."docker0"`),
  never publicly.

### 2. Morphic → ask.arsfeld.one

- `mkService "ask"`, `image = "ghcr.io/miurla/morphic:latest"`, `port = 3000`,
  `bypassAuth = true`, `tailscaleExposed = true`, `watchImage = true`.
- `container.network = "ask"` (dedicated docker network, created like galactica's
  `ai` network) so it reaches its DB/Redis sidecars by name.
- `container.extraOptions = ["--add-host=host.docker.internal:host-gateway"]`
  for SearXNG.
- Env via `morphic-env` sops secret (reuse galactica's OpenRouter key value):
  - `OPENAI_COMPATIBLE_API_KEY` (OpenRouter key)
  - `OPENAI_COMPATIBLE_API_BASE_URL=https://openrouter.ai/api/v1`
  - `OPENAI_COMPATIBLE_PROVIDER_NAME=OpenRouter`
  - `DATABASE_URL=postgresql://morphic:<pw>@morphic-postgres:5432/morphic`
  - `DATABASE_SSL_DISABLED=true`
  - `LOCAL_REDIS_URL=redis://morphic-redis:6379`
  - `SEARCH_API=searxng`, `SEARXNG_API_URL=http://host.docker.internal:8888`
  - `ENABLE_AUTH=false` (guest mode; edge auth handles access)
- **Model:** configure DeepSeek V4 (`deepseek/deepseek-v4-flash`, with
  `deepseek/deepseek-v4-pro` available) in Morphic's model config.

**Sidecars** (containers via `mkService`, `network = "ask"`, no gateway entry —
`port = null`, `configDir = null`):
- `morphic-postgres` — `postgres:17-alpine`, volume `/var/data/morphic-postgres`,
  `POSTGRES_USER/PASSWORD/DB=morphic` (password from `morphic-env`).
- `morphic-redis` — `redis:alpine`, `--appendonly yes`, volume
  `/var/data/morphic-redis`.

### 3. Open WebUI → webui.arsfeld.one

- `mkService "webui"`, `image = "ghcr.io/open-webui/open-webui:main"`,
  `port = 8080`, `bypassAuth = true`, `tailscaleExposed = true`,
  `watchImage = true`. Data at `/var/data/open-webui`
  (`container.configDir` mapped to `/app/backend/data`).
- `container.extraOptions = ["--add-host=host.docker.internal:host-gateway"]`.
- Env (or Admin UI as fallback; env names can vary by version — pin to current):
  - OpenRouter: `OPENAI_API_BASE_URL=https://openrouter.ai/api/v1`,
    `OPENAI_API_KEY` (from `open-webui-env` sops secret).
  - Web search: `ENABLE_WEB_SEARCH=true`, `WEB_SEARCH_ENGINE=searxng`,
    `SEARXNG_QUERY_URL=http://host.docker.internal:8888/search?q=<query>`.
  - Reranking: `RAG_RERANKING_MODEL` = a CPU cross-encoder (e.g.
    `BAAI/bge-reranker-v2-m3`); enable hybrid search. Model loads locally on
    aarch64 CPU (fine for interactive reranking).
  - `WEBUI_SECRET_KEY` (from `open-webui-env`).
- **Model:** select `deepseek/deepseek-v4-flash` after the OpenRouter
  connection is configured. Open WebUI keeps its own user accounts (first
  sign-up = admin); that's an extra layer behind the CF edge — acceptable.

### 4. Edge authentication

`ask.arsfeld.one` and `webui.arsfeld.one` become publicly reachable via the
shared tunnel with `bypassAuth`. **Cloudflare Zero Trust Access apps** on both
hostnames enforce auth at the edge (dashboard action, user-owned). Tailnet
access (`*.bat-boa.ts.net`) needs no extra auth.

### 5. Permanent move — clean up galactica

- Delete `hosts/galactica/services/ask.nix`; remove its `default.nix` import.
- Remove `hosts/galactica/services/morphic.nix` import (and file) so the
  `morphic.bat-boa.ts.net` tsnsrv node doesn't collide when galactica returns.
- galactica's `morphic-env` secret may remain (harmless).

## Secrets (added to `secrets/sops/basestar.yaml`)

| Secret | Contents |
|--------|----------|
| `searxng-env` | `SEARXNG_SECRET_KEY` |
| `morphic-env` | `OPENAI_COMPATIBLE_*` (reuse galactica OpenRouter key), `DATABASE_URL`, postgres password, `LOCAL_REDIS_URL` |
| `open-webui-env` | `OPENAI_API_KEY` (same OpenRouter key), `WEBUI_SECRET_KEY` |

## Files touched

| File | Change |
|------|--------|
| `hosts/basestar/services/search.nix` | **new** — native SearXNG |
| `hosts/basestar/services/ask.nix` | **new** — Morphic + postgres + redis sidecars + `ask` network |
| `hosts/basestar/services/webui.nix` | **new** — Open WebUI |
| `hosts/basestar/services/default.nix` | add the three imports |
| `hosts/basestar/configuration.nix` | docker-bridge firewall for 8888; secret decls |
| `secrets/sops/basestar.yaml` | add `searxng-env`, `morphic-env`, `open-webui-env` |
| `hosts/galactica/services/ask.nix` | **delete** |
| `hosts/galactica/services/morphic.nix` | **delete** |
| `hosts/galactica/services/default.nix` | remove `ask.nix` + `morphic.nix` imports |

## Models

Single OpenRouter key (reused from galactica's `morphic-env`) drives both apps.

- **Default chat model:** `deepseek/deepseek-v4-flash` — DeepSeek V4 (2026-04-24),
  284B MoE/13B active, 1M context, function/tool use, ~$0.09/$0.18 per M.
- **Quality tier:** `deepseek/deepseek-v4-pro` (~$0.435/$0.87) for hard queries.
- **Open WebUI reranker:** local CPU cross-encoder (`bge-reranker-v2-m3` or
  similar) — the retrieval-quality edge Morphic lacks.
- Avoid Gemini previews on OpenRouter (503/rate-limit).

## Verification

1. `just build basestar` and `just build galactica` (after galactica removals).
2. `just deploy basestar`.
3. On basestar: `docker ps` shows `ask`, `morphic-postgres`, `morphic-redis`,
   `webui`, and SearXNG/uwsgi healthy; containers can curl
   `http://host.docker.internal:8888`.
4. `https://ask.arsfeld.one` (Morphic) and `https://webui.arsfeld.one`
   (Open WebUI) load behind CF Access; `*.bat-boa.ts.net` load on tailnet.
5. Configure DeepSeek V4 in both; in Open WebUI enable web search + reranking.
6. Run the same query in both, compare cited results; pick the winner and
   (optionally) repoint `ask` to it.

## Out of scope / non-goals

- Migrating galactica's old Vane/Morphic data (galactica unreachable; reconfigure
  via UI / env).
- Khoj (evaluated, not selected).
- Cloudflare Access app creation (dashboard, user action).
