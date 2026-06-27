# ask.arsfeld.one — Vane (Perplexica) on basestar

**Date:** 2026-06-27
**Status:** Approved (pending spec review)
**Scope:** Permanently move the `ask.arsfeld.one` AI-search service from galactica
(currently down) to basestar.

## Background

`ask.arsfeld.one` already runs **Vane** (`itzcrazykns1337/vane`, the rebranded
successor to Perplexica by the same author) on galactica. galactica is down, so
the URL is dead. This spec moves the service to basestar **permanently**.

### Why Vane (not Morphic)

Both are configured on galactica. Morphic has better model flexibility but **no
embedding/reranking stage** — it feeds raw SearXNG results to the model, which
gave mixed retrieval quality. Vane's defining feature *is* embedding-based
reranking of search results before synthesis, and it is equally model-agnostic
(OpenRouter → any chat model). Vane therefore gives Morphic's model flexibility
*plus* the retrieval quality Morphic lacks. It is MIT-licensed, actively
maintained (v1.12.x), and ships a native `linux/arm64` image (verified via
`skopeo inspect`), so it runs on aarch64 basestar without emulation.

## Routing — why this works with galactica down

- basestar's cloudflared runs on the **same tunnel UUID** as galactica
  (`f53e532a-...`, connector redundancy). With galactica down, `*.arsfeld.one`
  traffic is served by basestar's connector.
- basestar has `media.gateway.enable = true` with `media.config.domain =
  "arsfeld.one"`, so the Caddy gateway already serves `*.arsfeld.one` vhosts on
  `https://localhost`, which the tunnel ingress targets.

```
ask.arsfeld.one ──cloudflared (shared tunnel)──▶ Caddy gateway (localhost)
                                                     │
                                                     ▼
                                         Vane container ("ask", :3000)
                                             │              │
       OpenRouter (chat + embeddings) ◀──────┘              │ SEARXNG_API_URL
                                                            ▼
                                          SearXNG (native NixOS service, :8888)
ask.bat-boa.ts.net ──tsnsrv──▶ Vane (tailnet access)
```

## Components

All on basestar, **docker** backend (basestar runs docker, units are
`docker-<name>`). Every service goes through `mkService`.

### 1. SearXNG (native)

Replicate galactica's `hosts/galactica/services/search.nix` on basestar:

- `mkService "search"` with `port = 8888`, `tailscaleExposed = true` — also
  yields `search.arsfeld.one` as a bonus.
- `services.searx` (uwsgi, `redisCreateLocally = true`) using the
  nixpkgs-unstable `searxng` override rebuilt against stable `python3` (same
  engine fixes as galactica: duckduckgo headers, google params).
- New sops secret `searxng-env` in `secrets/sops/basestar.yaml` providing
  `SEARXNG_SECRET_KEY`, owned by the `searx` user.
- Same engine tuning as galactica (brave/startpage/wikidata/mojeek disabled,
  bing enabled, `formats = ["html" "json"]`).

### 2. ask (Vane)

`mkService "ask"` on basestar:

- `image = "itzcrazykns1337/vane:latest"`, `port = 3000`.
- `bypassAuth = true` — galactica's Authelia is down; auth enforced at the
  Cloudflare edge instead (see §3). Mirrors the existing `chat` service.
- `tailscaleExposed = true` — `ask.bat-boa.ts.net` for tailnet access.
- `watchImage = true` — poll registry, restart on new image.
- `container.configDir = "/home/vane/data"`, persisted at `/var/data/ask`
  (config.json holds the model + OpenRouter key, entered via the web UI).
- `container.environment.SEARXNG_API_URL = "http://host.docker.internal:8888"`.
- `container.extraOptions = ["--add-host=host.docker.internal:host-gateway"]`
  so the container can reach the host's native SearXNG.

### 3. Edge authentication

`ask.arsfeld.one` becomes publicly reachable via the shared tunnel with
`bypassAuth`. As with `chat`, a **Cloudflare Zero Trust Access app** on
`ask.arsfeld.one` enforces authentication at the edge. This is configured in the
Cloudflare dashboard (not in this repo) and must be confirmed/created by the
user. Tailnet access (`ask.bat-boa.ts.net`) needs no extra auth.

### 4. Models (no sops; configured in Vane UI)

Vane stores provider config + API keys in its data dir (`/var/data/ask`), set
through the web UI on first run:

- **Chat model:** OpenRouter, recommended `openai/gpt-4o-mini` (stable, cheap,
  reliably drives Vane's agentic search per galactica's notes).
- **Embedding model:** OpenRouter's OpenAI-compatible embeddings endpoint —
  base URL `https://openrouter.ai/api/v1`, an OpenRouter embedding model. Same
  key as chat. This is the retrieval-quality fix that was missing.

### 5. Permanent move — remove from galactica

- Delete `hosts/galactica/services/ask.nix`.
- Remove its import from `hosts/galactica/services/default.nix`.

This prevents the shared tunnel from round-robining between galactica's and
basestar's `ask` (and split config/data) once galactica returns. Morphic on
galactica is left untouched (out of scope).

## Networking detail: docker → host SearXNG

Vane (docker container) reaches the host's native SearXNG on `:8888` via
`host.docker.internal` (mapped to `host-gateway`). The host firewall must allow
`8888` on the docker bridge interface. basestar's firewall only opens 22/80/443
publicly; add docker-bridge access for 8888 (e.g.
`networking.firewall.interfaces."docker0".allowedTCPPorts = [8888]` or trust the
bridge interface) without exposing 8888 publicly. uwsgi already binds `:8888`
(all interfaces) as on galactica.

## Files touched

| File | Change |
|------|--------|
| `hosts/basestar/services/search.nix` | **new** — native SearXNG (port via `media.config`) |
| `hosts/basestar/services/ask.nix` | **new** — Vane via `mkService` |
| `hosts/basestar/services/default.nix` | add both imports |
| `hosts/basestar/configuration.nix` or `ask.nix`/`search.nix` | docker-bridge firewall for 8888; `searxng-env` secret decl |
| `secrets/sops/basestar.yaml` | add `searxng-env` (SEARXNG_SECRET_KEY) |
| `hosts/galactica/services/ask.nix` | **delete** |
| `hosts/galactica/services/default.nix` | remove `ask.nix` import |

## Verification

1. `just build basestar` succeeds (and `just build galactica` after removal).
2. `just deploy basestar`.
3. On basestar: `docker ps` shows `ask` and SearXNG/uwsgi healthy; `curl
   localhost:8888` returns SearXNG; container can reach
   `http://host.docker.internal:8888`.
4. `https://ask.arsfeld.one` loads (Cloudflare Access challenge → Vane UI);
   `https://ask.bat-boa.ts.net` loads on tailnet.
5. Configure OpenRouter chat + embedding models in the UI; run a query and
   confirm cited, reranked results.

## Out of scope / non-goals

- Migrating galactica's existing Vane config/data (galactica is unreachable;
  re-enter the OpenRouter key in the UI).
- Morphic (left as-is on galactica).
- Cloudflare Access app creation (dashboard, user action).
