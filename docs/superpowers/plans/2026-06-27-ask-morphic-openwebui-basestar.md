# ask.arsfeld.one — Morphic + Open WebUI on basestar — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stand up two AI web-search engines on basestar — Morphic at `ask.arsfeld.one` and Open WebUI at `webui.arsfeld.one` — both on DeepSeek V4 via OpenRouter, sharing one native SearXNG, and remove the dead Vane/Morphic services from galactica.

**Architecture:** All services declared via `mkService` (docker backend). Native SearXNG (copied from galactica) serves both engines and `search.arsfeld.one`. Morphic + its postgres/redis sidecars + Open WebUI all join one docker network `ask` (fixed bridge `ask0`); they reach the host's SearXNG via `host.docker.internal:8888`, opened only on `ask0`. Public access is via basestar's shared `*.arsfeld.one` cloudflared tunnel + Caddy gateway, with `bypassAuth` and Cloudflare edge auth.

**Tech Stack:** NixOS, flake-parts, `mkService` (`modules/media/__mkService.nix`), oci-containers (docker), sops-nix, SearXNG (NixOS module), Caddy gateway, Colmena deploy.

**Spec:** `docs/superpowers/specs/2026-06-27-ask-vane-basestar-design.md`

> **Implementation note (superseded in part):** Tasks 1–5 were executed as written,
> but the docker runtime on basestar hit a Docker 29 + nftables conflict (firewall
> reloads flushed docker's NAT chains). The fix was to **migrate basestar to podman**,
> which also let Morphic use the **system PostgreSQL** and drop the custom docker
> network, the containerized PG/Redis sidecars, Redis entirely, and all per-app
> firewall rules. The **as-built** architecture is in the spec above; the task steps
> below reflect the original docker design and are kept as the execution record.

---

## Reference: the design's verified facts

- basestar runs **docker** (`constellation.docker.enable`); container units are `docker-<name>`. Use `image =` overrides (the `mkService` default is `ghcr.io/linuxserver/<name>`, wrong for these).
- `mkService "<name>" { port; image; bypassAuth; tailscaleExposed; watchImage; container = {...}; }` writes `media.containers.<name>` and auto-creates the gateway vhost when `port` (listenPort) is non-null. `port = null` ⇒ container created, no host port, no vhost (used for sidecars).
- Every container auto-gets `PUID/PGID/TZ` env and a `${configDir}/<name>:<container.configDir>` mount unless `container.configDir = null`.
- `container.network = "ask"` adds `--network=ask`; `container.extraOptions` is appended verbatim.
- Reuse the existing OpenRouter API key from galactica's `morphic-env` secret (`OPENAI_COMPATIBLE_API_KEY=sk-or-v1-...`). View it with: `nix develop -c sops --decrypt secrets/sops/galactica.yaml`.
- Default model: `deepseek/deepseek-v4-flash`; quality tier `deepseek/deepseek-v4-pro`.

Run all `git`/`nix`/`sops`/`just` commands from the repo root `/home/arosenfeld/Code/nixos`, inside `nix develop` (or prefix with `nix develop -c`).

---

## Task 1: Add basestar secrets (searxng-env, morphic-env, open-webui-env)

**Files:**
- Modify (encrypted): `secrets/sops/basestar.yaml`

- [ ] **Step 1: Read galactica's OpenRouter key and morphic password to reuse**

Run:
```bash
nix develop -c sops --decrypt secrets/sops/galactica.yaml | grep -A4 'morphic-env'
```
Expected: prints `OPENAI_COMPATIBLE_API_KEY=sk-or-v1-...`, `OPENAI_COMPATIBLE_API_BASE_URL`, `OPENAI_COMPATIBLE_PROVIDER_NAME`, and a `DATABASE_URL` line. Copy the `OPENAI_COMPATIBLE_API_KEY` value — call it `<OPENROUTER_KEY>` below.

- [ ] **Step 2: Generate two random secrets (postgres password, webui secret key)**

Run:
```bash
echo "PG_PW=$(openssl rand -hex 24)"; echo "WEBUI_KEY=$(openssl rand -hex 32)"
```
Expected: two hex strings. Call them `<PG_PW>` and `<WEBUI_KEY>`.

- [ ] **Step 3: Open basestar's sops file and add the three secrets**

Run:
```bash
nix develop -c sops secrets/sops/basestar.yaml
```
Add these three top-level keys (YAML block scalars), substituting the values from Steps 1–2:
```yaml
searxng-env: |
    SEARXNG_SECRET_KEY=GENERATE_WITH_openssl_rand_hex_32
morphic-env: |
    OPENAI_COMPATIBLE_API_KEY=<OPENROUTER_KEY>
    OPENAI_COMPATIBLE_API_BASE_URL=https://openrouter.ai/api/v1
    OPENAI_COMPATIBLE_PROVIDER_NAME=OpenRouter
    DATABASE_URL=postgresql://morphic:<PG_PW>@morphic-postgres:5432/morphic
    DATABASE_SSL_DISABLED=true
    POSTGRES_USER=morphic
    POSTGRES_PASSWORD=<PG_PW>
    POSTGRES_DB=morphic
    LOCAL_REDIS_URL=redis://morphic-redis:6379
    SEARCH_API=searxng
    SEARXNG_API_URL=http://host.docker.internal:8888
    ENABLE_AUTH=false
open-webui-env: |
    OPENAI_API_KEY=<OPENROUTER_KEY>
    WEBUI_SECRET_KEY=<WEBUI_KEY>
```
For `SEARXNG_SECRET_KEY`, replace the placeholder with the output of `openssl rand -hex 32`. Save and close the editor (sops re-encrypts on save).

- [ ] **Step 4: Verify the secrets decrypt and contain the three keys**

Run:
```bash
nix develop -c sops --decrypt secrets/sops/basestar.yaml | grep -E 'searxng-env|morphic-env|open-webui-env'
```
Expected: all three keys listed.

- [ ] **Step 5: Commit**

```bash
git add secrets/sops/basestar.yaml
git commit -m "chore(secrets): add basestar searxng/morphic/open-webui env"
```

---

## Task 2: Native SearXNG on basestar

**Files:**
- Create: `hosts/basestar/services/search.nix`
- Modify: `hosts/basestar/services/default.nix`

- [ ] **Step 1: Create `hosts/basestar/services/search.nix`**

This is galactica's `search.nix` adapted (declares the `searxng-env` secret with `owner = "searx"`; identical engine tuning):
```nix
{
  self,
  config,
  pkgs,
  inputs,
  lib,
  ...
}: let
  mkService = import "${self}/modules/media/__mkService.nix" {inherit lib;};
  port = 8888;
  # nixpkgs-unstable searxng for engine fixes, rebuilt against stable python3
  # so the NixOS uwsgi vassal can construct a working env.
  pkgs-unstable = import inputs.nixpkgs-unstable {
    system = pkgs.stdenv.hostPlatform.system;
    config = pkgs.config;
  };
  searxng = pkgs-unstable.searxng.override {python3 = pkgs.python3;};
in
  lib.mkMerge [
    (mkService "search" {
      inherit port;
      tailscaleExposed = true;
    })

    {
      sops.secrets.searxng-env = {
        owner = "searx";
      };

      services.searx = {
        enable = true;
        package = searxng;
        runInUwsgi = true;
        redisCreateLocally = true;
        environmentFile = config.sops.secrets.searxng-env.path;

        uwsgiConfig = {
          http = ":${toString port}";
          disable-logging = true;
        };

        settings = {
          general = {
            instance_name = "Search";
            privacypolicy_url = false;
            donation_url = false;
            contact_url = false;
            enable_metrics = false;
          };
          server = {
            secret_key = "$SEARXNG_SECRET_KEY";
            limiter = false;
            image_proxy = true;
            method = "GET";
          };
          ui = {
            static_use_hash = true;
            default_theme = "simple";
            theme_args.simple_style = "dark";
          };
          search = {
            safe_search = 0;
            autocomplete = "duckduckgo";
            formats = ["html" "json"];
          };
          engines = [
            {
              name = "brave";
              disabled = true;
            }
            {
              name = "startpage";
              disabled = true;
            }
            {
              name = "wikidata";
              disabled = true;
            }
            {
              name = "bing";
              disabled = false;
            }
            {
              name = "mojeek";
              disabled = true;
            }
          ];
        };
      };
    }
  ]
```

- [ ] **Step 2: Add the import to `hosts/basestar/services/default.nix`**

In the `imports` list, add `./search.nix` (alphabetical-ish, e.g. after `./rustdesk.nix`):
```nix
    ./rustdesk.nix
    ./search.nix
    ./sillytavern.nix
```

- [ ] **Step 3: Build basestar to verify SearXNG evaluates and builds**

Run:
```bash
just build basestar
```
Expected: build succeeds (no eval error; searxng + uwsgi in the closure).

- [ ] **Step 4: Commit**

```bash
git add hosts/basestar/services/search.nix hosts/basestar/services/default.nix
git commit -m "feat(basestar): add native SearXNG (search.arsfeld.one)"
```

---

## Task 3: Morphic + postgres + redis + the `ask` docker network → ask.arsfeld.one

**Files:**
- Create: `hosts/basestar/services/ask.nix`
- Modify: `hosts/basestar/services/default.nix`

- [ ] **Step 1: Create `hosts/basestar/services/ask.nix`**

```nix
{
  self,
  config,
  pkgs,
  lib,
  ...
}: let
  mkService = import "${self}/modules/media/__mkService.nix" {inherit lib;};
  # Container units (oci-containers, docker backend) that must wait for the
  # shared "ask" network to exist.
  askNetUnits = ["docker-ask" "docker-webui" "docker-morphic-postgres" "docker-morphic-redis"];
in
  lib.mkMerge [
    {sops.secrets."morphic-env" = {};}

    # Morphic — ask.arsfeld.one. Reaches postgres/redis by name on the "ask"
    # network; reaches host SearXNG via host.docker.internal.
    (mkService "ask" {
      port = 3000;
      image = "ghcr.io/miurla/morphic:latest";
      bypassAuth = true; # auth at the Cloudflare edge (galactica Authelia is down)
      tailscaleExposed = true; # ask.bat-boa.ts.net
      watchImage = true;
      container = {
        configDir = null; # morphic keeps state in postgres, not /config
        network = "ask";
        environmentFiles = [config.sops.secrets."morphic-env".path];
        extraOptions = ["--add-host=host.docker.internal:host-gateway"];
      };
    })

    # Postgres sidecar (no gateway entry, no host port).
    (mkService "morphic-postgres" {
      image = "postgres:17-alpine";
      container = {
        configDir = null;
        network = "ask";
        environmentFiles = [config.sops.secrets."morphic-env".path];
        volumes = ["/var/data/morphic-postgres:/var/lib/postgresql/data"];
      };
    })

    # Redis sidecar (no gateway entry, no host port).
    (mkService "morphic-redis" {
      image = "redis:alpine";
      cmd = ["redis-server" "--appendonly" "yes"];
      container = {
        configDir = null;
        network = "ask";
        volumes = ["/var/data/morphic-redis:/data"];
      };
    })

    {
      # Create the shared docker network with a deterministic bridge name so the
      # firewall rule below can target it; and make every ask-network container
      # start after the network exists. Both are merged into systemd.services
      # via mkMerge (defining systemd.services twice in one attrset is an error).
      systemd.services = lib.mkMerge [
        {
          create-docker-ask-network = {
            description = "Create Docker ask network";
            after = ["docker.service"];
            requires = ["docker.service"];
            wantedBy = ["multi-user.target"];
            serviceConfig = {
              Type = "oneshot";
              RemainAfterExit = true;
            };
            script = ''
              ${pkgs.docker}/bin/docker network inspect ask >/dev/null 2>&1 || \
                ${pkgs.docker}/bin/docker network create \
                  --opt com.docker.network.bridge.name=ask0 ask
            '';
          };
        }
        (lib.genAttrs askNetUnits (_: {
          after = ["create-docker-ask-network.service"];
          requires = ["create-docker-ask-network.service"];
        }))
      ];

      # SearXNG (host :8888) reachable only from the ask network's bridge.
      networking.firewall.interfaces."ask0".allowedTCPPorts = [8888];
    }
  ]
```

- [ ] **Step 2: Add the import to `hosts/basestar/services/default.nix`**

Add `./ask.nix` to the `imports` list (e.g. right after the opening, before `./blog.nix`):
```nix
    ./ask.nix
    ./blog.nix
```

- [ ] **Step 3: Build basestar to verify it evaluates**

Run:
```bash
just build basestar
```
Expected: build succeeds. (The `genAttrs` systemd overrides merge with the oci-containers-generated units; no "option defined multiple times" error because they set disjoint sub-options.)

- [ ] **Step 4: Commit**

```bash
git add hosts/basestar/services/ask.nix hosts/basestar/services/default.nix
git commit -m "feat(basestar): add Morphic (ask.arsfeld.one) with postgres/redis + ask network"
```

---

## Task 4: Open WebUI → webui.arsfeld.one

**Files:**
- Create: `hosts/basestar/services/webui.nix`
- Modify: `hosts/basestar/services/default.nix`

- [ ] **Step 1: Create `hosts/basestar/services/webui.nix`**

```nix
{
  self,
  config,
  lib,
  ...
}: let
  mkService = import "${self}/modules/media/__mkService.nix" {inherit lib;};
in
  lib.mkMerge [
    {sops.secrets."open-webui-env" = {};}

    (mkService "webui" {
      port = 8080;
      image = "ghcr.io/open-webui/open-webui:main";
      bypassAuth = true; # Open WebUI has its own login; CF edge in front
      tailscaleExposed = true; # webui.bat-boa.ts.net
      watchImage = true;
      container = {
        configDir = "/app/backend/data"; # -> /var/data/webui:/app/backend/data
        network = "ask"; # share the network so host.docker.internal opens only ask0
        environmentFiles = [config.sops.secrets."open-webui-env".path];
        extraOptions = ["--add-host=host.docker.internal:host-gateway"];
        environment = {
          # OpenRouter as the OpenAI-compatible backend (key is in env file).
          OPENAI_API_BASE_URL = "https://openrouter.ai/api/v1";
          # Web search via the host's native SearXNG.
          ENABLE_WEB_SEARCH = "true";
          WEB_SEARCH_ENGINE = "searxng";
          SEARXNG_QUERY_URL = "http://host.docker.internal:8888/search?q=<query>";
          # Reranking: hybrid search + a CPU cross-encoder (downloaded at runtime).
          ENABLE_RAG_HYBRID_SEARCH = "true";
          RAG_RERANKING_MODEL = "BAAI/bge-reranker-v2-m3";
        };
      };
    })
  ]
```

- [ ] **Step 2: Add the import to `hosts/basestar/services/default.nix`**

Add `./webui.nix` to the `imports` list (after `./vault.nix`):
```nix
    ./vault.nix
    ./webui.nix
    ./yarr.nix
```

- [ ] **Step 3: Build basestar to verify it evaluates**

Run:
```bash
just build basestar
```
Expected: build succeeds.

- [ ] **Step 4: Commit**

```bash
git add hosts/basestar/services/webui.nix hosts/basestar/services/default.nix
git commit -m "feat(basestar): add Open WebUI (webui.arsfeld.one) with SearXNG + reranking"
```

---

## Task 5: Remove dead ask + morphic from galactica

**Files:**
- Delete: `hosts/galactica/services/ask.nix`
- Delete: `hosts/galactica/services/morphic.nix`
- Modify: `hosts/galactica/services/default.nix`

- [ ] **Step 1: Remove the two imports from `hosts/galactica/services/default.nix`**

Delete these two lines from the `imports` list:
```nix
    ./ask.nix
```
and
```nix
    ./morphic.nix
```

- [ ] **Step 2: Delete the two service files**

Run:
```bash
git rm hosts/galactica/services/ask.nix hosts/galactica/services/morphic.nix
```
Expected: both files staged for deletion.

- [ ] **Step 3: Build galactica to verify nothing else referenced them**

Run:
```bash
just build galactica
```
Expected: build succeeds (no dangling reference to `ask`/`morphic` services).

- [ ] **Step 4: Commit**

```bash
git add hosts/galactica/services/default.nix
git commit -m "chore(galactica): remove ask (Vane) and morphic; moved to basestar"
```

---

## Task 6: Deploy basestar and verify end-to-end

**Files:** none (deploy + runtime verification)

- [ ] **Step 1: Final build of both hosts**

Run:
```bash
just build basestar && just build galactica
```
Expected: both succeed.

- [ ] **Step 2: Deploy basestar**

Run:
```bash
just deploy basestar
```
Expected: Colmena activates without error. (galactica is down — do not deploy it now; it will pick up the removal next time it's deployed.)

- [ ] **Step 3: Verify the network, containers, and SearXNG on basestar**

Run (over Tailscale SSH):
```bash
ssh basestar.bat-boa.ts.net 'docker network inspect ask -f "{{.Options}}"; docker ps --format "{{.Names}}\t{{.Status}}" | grep -E "ask|webui|morphic|"; systemctl is-active searx-init searx || systemctl is-active uwsgi'
```
Expected: network `ask` exists with bridge name `ask0`; containers `ask`, `webui`, `morphic-postgres`, `morphic-redis` are `Up`; SearXNG/uwsgi active.

- [ ] **Step 4: Verify containers can reach host SearXNG**

Run:
```bash
ssh basestar.bat-boa.ts.net 'docker exec ask sh -c "wget -qO- http://host.docker.internal:8888/search?q=test\&format=json | head -c 80" || docker exec ask sh -c "curl -s http://host.docker.internal:8888/search?q=test\&format=json | head -c 80"'
```
Expected: JSON output (not a connection error) — confirms `ask0` firewall opening works.

- [ ] **Step 5: Verify both vhosts resolve through the gateway**

Run:
```bash
curl -sS -o /dev/null -w "ask=%{http_code}\n"   https://ask.arsfeld.one
curl -sS -o /dev/null -w "webui=%{http_code}\n" https://webui.arsfeld.one
```
Expected: HTTP codes from the apps / Cloudflare Access (e.g. 200 or a 302/403 Access challenge), not 404/502.

- [ ] **Step 6: Manual app configuration (one-time, in each UI)**

Do these in a browser, then run one query in each and confirm cited results:
- **Cloudflare dashboard:** create Zero Trust Access apps for `ask.arsfeld.one` and `webui.arsfeld.one` (mirror the existing `chat.arsfeld.one` policy).
- **Morphic (`ask.arsfeld.one`):** confirm it loads in guest mode; set the model to `deepseek/deepseek-v4-flash` in Morphic's model selector/config.
- **Open WebUI (`webui.arsfeld.one`):** first sign-up becomes admin; in Admin → Settings → Connections confirm the OpenRouter base URL/key; select `deepseek/deepseek-v4-flash`; in Admin → Settings → Web Search confirm SearXNG is enabled; in Documents/RAG confirm hybrid search + reranking model are active.

- [ ] **Step 7: Record the outcome**

After comparing both on the same query, note the winner. If desired, repoint `ask.arsfeld.one` to the winner in a follow-up change. No commit needed for this step.

---

## Self-Review notes (addressed)

- **Spec coverage:** SearXNG (Task 2), Morphic+sidecars+network+firewall (Task 3), Open WebUI (Task 4), galactica cleanup (Task 5), secrets (Task 1), edge auth + model config + verification (Task 6). All spec sections mapped.
- **Sidecars with `port = null`:** verified in `modules/media/containers.nix` — containers are created for all enabled entries; host port mapping and gateway vhost are only added when `listenPort != null`.
- **Network ordering:** `create-docker-ask-network` + `genAttrs` overrides ensure the four containers start after the network; bridge name pinned to `ask0` for the firewall rule.
- **Secrets out of the nix store:** all credentials (OpenRouter key, postgres password, webui key, searxng secret) are passed via `environmentFiles`/`environmentFile` from sops, never in `environment` literals.
