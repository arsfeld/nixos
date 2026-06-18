# SillyTavern (NSFW chat + image generation) on basestar — Design

**Date:** 2026-06-17
**Status:** Approved, pending implementation plan
**Target host:** basestar (aarch64-linux)

## Goal

A self-hosted, single-user adult chatbot with image generation, using cloud
APIs for the heavy lifting. SillyTavern provides the frontend (character cards,
personas, memory, inline image generation); OpenRouter provides the text model;
Stable Horde provides image generation. Access is restricted to the owner's
tailnet.

## Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Scope / users | Single user (owner only) | Simplest; no multi-user or moderation burden |
| Exposure | Tailscale-only | No public attack surface |
| Frontend | SillyTavern | De-facto NSFW/roleplay frontend; native image-gen integration; OpenAI-compatible text backend |
| Host | basestar | galactica is down; basestar currently serves the constellation |
| Access wiring | Gateway-less container + **manual tsnsrv node** → `chat.bat-boa.ts.net` | Genuinely tailnet-only; no Caddy vhost, so nothing is reachable through basestar's `*.arsfeld.one` Cloudflare tunnel; no dependency on galactica's Authelia (which is down) |
| Text API | OpenRouter | Single key, pay-per-token, OpenAI-compatible, uncensored models available |
| Image API | Stable Horde | Free, NSFW-permitting, native SillyTavern integration, zero infra |
| Config | Env vars (`SILLYTAVERN_*`) | Declarative; no config file to mount |
| Secrets | Entered in UI, persisted in data volume | No sops plumbing needed |
| Backup | None added | `/var/data` already covered by basestar's backrest plan |

## Why not the alternatives

- **`chat.arsfeld.one` vhost (rejected):** basestar serves `*.arsfeld.one` via
  the Cloudflare tunnel (`hosts/basestar/services/cloudflared.nix`, wildcard
  `*.arsfeld.one → https://localhost`), making it **publicly internet-reachable**
  — contradicts the Tailscale-only goal. Worse, basestar forwards auth to
  galactica's Authelia (`authHost = auth.bat-boa.ts.net`), which is **down**, so
  the route is currently either broken (`bypassAuth = false`) or an open NSFW
  service on the public internet (`bypassAuth = true`).
- **`mkService` gateway path + `tailscaleExposed` (rejected):** registering a
  gateway service (which `mkService` does automatically for any container with a
  non-null `port`) generates a Caddy vhost at `<name>.arsfeld.one`. Because the
  cloudflared ingress is a wildcard, that vhost is **publicly reachable through
  the tunnel** even though we only wanted the tailnet node. With `bypassAuth =
  true` (and Authelia down) that is an open NSFW service on the internet. The
  fix is a **gateway-less container** (`port = null`, published only on
  loopback) plus a **manually declared `services.tsnsrv.services` node** — no
  Caddy vhost is created, so nothing is exposed via cloudflared. This mirrors the
  existing `hosts/basestar/services/gatus.nix` pattern.
- **Mainstream LLM APIs (OpenAI/Anthropic/Google):** prohibit NSFW content;
  will refuse or ban. Hence OpenRouter with uncensored/unmoderated models.
- **Custom UI / local GPU image gen:** unnecessary work; reinvents what
  SillyTavern + Stable Horde already do.

## Architecture

```
You (tailnet) ──▶ chat.bat-boa.ts.net (tsnsrv) ──▶ SillyTavern (basestar, :8000)
                                                        │
                                  text ─────────────────┼──▶ OpenRouter (OpenAI-compatible)
                                  images ───────────────┴──▶ Stable Horde (native ST integration)
```

SillyTavern is the only self-hosted moving part. It is a lightweight Node.js
app, so aarch64 and basestar's resources are not a concern; the model inference
and image generation run entirely on cloud APIs. The container image
`ghcr.io/sillytavern/sillytavern` publishes a `linux/arm64` build, so it runs
natively on basestar with no cross-build.

## Implementation

### New file: `hosts/basestar/services/sillytavern.nix`

Declared via the `mkService` helper (`modules/media/__mkService.nix`), consistent
with the repo's service conventions. `port = null` makes it a **gateway-less
container** (no Caddy vhost, no public exposure). The container runs on basestar's
Docker oci backend (`virtualisation.oci-containers.backend = "docker"`), publishes
only on loopback, and is exposed to the tailnet by a manual tsnsrv node.

```nix
lib.mkMerge [
  (mkService "sillytavern" {
    port = null;                                 # gateway-less: no Caddy vhost, nothing on *.arsfeld.one
    image = "ghcr.io/sillytavern/sillytavern";   # multi-arch, runs on aarch64
    container = {
      configDir = "/home/node/app/config";       # ST's config path; mkService auto-mounts /var/data/sillytavern here
      environment = {
        SILLYTAVERN_LISTEN = "true";
        SILLYTAVERN_WHITELISTMODE = "false";      # behind reverse proxy / tailnet
        SILLYTAVERN_SECURITYOVERRIDE = "true";    # allow running with whitelist off behind a proxy
      };
      volumes = ["/var/data/sillytavern-data:/home/node/app/data"];  # chats, characters, entered API keys
      extraOptions = ["--publish=127.0.0.1:18000:8000"];             # loopback only; tsnsrv reaches it here
    };
  })
  {
    # Tailnet-only access; mirrors hosts/basestar/services/gatus.nix.
    services.tsnsrv.services.chat = {
      toURL = "http://127.0.0.1:18000";
      funnel = false;
    };
  }
]
```

Verified facts (no longer open questions):
- **Gateway-less pattern:** with `port = null`, `mkService` writes
  `media.containers.sillytavern` with `listenPort = null`, so no
  `media.gateway.services` entry and no Caddy vhost are created
  (`modules/media/containers.nix`). The module does not publish any port when
  `listenPort == null`, so the container publishes its host port via the explicit
  `--publish` in `extraOptions`.
- **Config dir mount:** `mkService`/`containers.nix` auto-mounts
  `${configDir}/<name>` → `container.configDir`, i.e. `/var/data/sillytavern` →
  `/home/node/app/config`. tmpfiles creates both `/var/data/sillytavern` and the
  managed volume dir `/var/data/sillytavern-data`, owned `media:media` (5000).
- **PUID/PGID/TZ:** injected automatically by `containers.nix` from `media.config`
  (5000/5000). The `ghcr.io/sillytavern/sillytavern` image honors `PUID`/`PGID`.
- **Env var names:** confirmed against SillyTavern docs — `SILLYTAVERN_<KEY>`
  uppercase maps to `config.yaml` keys, so `SILLYTAVERN_LISTEN`,
  `SILLYTAVERN_WHITELISTMODE`, `SILLYTAVERN_SECURITYOVERRIDE` are correct.
- **tsnsrv node:** `services.tsnsrv` is already enabled on basestar with
  `defaults.authKeyPath` set (`hosts/basestar/services.nix`), so the manual
  `services.tsnsrv.services.chat` entry yields `chat.bat-boa.ts.net` with no extra
  wiring.
- **No `watchImage`:** the image-watch script in `containers.nix` hardcodes
  `pkgs.podman`, but basestar uses the Docker backend, so `watchImage` is left
  off (default). Updates are manual (`docker pull` + restart).

### Edit: `hosts/basestar/services/default.nix`

Add `./sillytavern.nix` to the `imports` list.

### Secrets

None in Nix. After deploy, enter the OpenRouter API key in SillyTavern's UI
(API Connections → Chat Completion → Custom / OpenRouter). Stable Horde works
anonymously with key `0000000000`; optionally register a free key for priority.
Keys persist in `/var/data/sillytavern-data` (`secrets.json`).

### Backup

No change. basestar's `constellation.backrest` `system` plan backs up
`/var/data` daily at 03:30, which covers both the config
(`/var/data/sillytavern`) and data (`/var/data/sillytavern-data`) paths.

## Verification

After `just deploy basestar`:

1. Container is healthy (`systemctl status docker-sillytavern` or
   `docker ps`), and the tsnsrv node `chat` is registered on the tailnet.
2. Open `https://chat.bat-boa.ts.net` from a tailnet device.
3. Configure text API: Chat Completion → OpenRouter (or Custom endpoint
   `https://openrouter.ai/api/v1`) with the API key, select an
   uncensored/unmoderated model.
4. Configure image source: Extensions → Image Generation → Stable Horde.
5. Generate one chat message and one image to confirm both cloud paths work
   end-to-end.

## Out of scope (YAGNI)

- Custom UI
- Local GPU image generation
- Authelia / multi-user / accounts
- Public `arsfeld.one` vhost (can be added later, auth-gated, once galactica is
  back)
- NovelAI or RunPod/ComfyUI image backends — addable later purely as an
  alternate image source in SillyTavern's UI, with no architecture change.
