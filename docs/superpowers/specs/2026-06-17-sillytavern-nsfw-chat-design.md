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
| Access wiring | `exposeViaTailscale` → `chat.bat-boa.ts.net` | Genuinely tailnet-only; no Cloudflare tunnel; no dependency on galactica's Authelia (which is down) |
| Text API | OpenRouter | Single key, pay-per-token, OpenAI-compatible, uncensored models available |
| Image API | Stable Horde | Free, NSFW-permitting, native SillyTavern integration, zero infra |
| Config | Env vars (`SILLYTAVERN_*`) | Declarative; no config file to mount |
| Secrets | Entered in UI, persisted in data volume | No sops plumbing needed |
| Backup | None added | `/var/data` already covered by basestar's backrest plan |

## Why not the alternatives

- **`chat.arsfeld.one` vhost (rejected):** basestar serves `*.arsfeld.one` via
  the Cloudflare tunnel (`hosts/basestar/services/cloudflared.nix`), making it
  **publicly internet-reachable** — contradicts the Tailscale-only goal. Worse,
  basestar forwards auth to galactica's Authelia (`authHost =
  auth.bat-boa.ts.net`), which is **down**, so the route is currently either
  broken (`bypassAuth = false`) or an open NSFW service on the public internet
  (`bypassAuth = true`). `exposeViaTailscale` avoids all of this.
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
with the repo's service conventions. The container runs on basestar's Docker oci
backend (`virtualisation.oci-containers.backend = "docker"`).

```nix
mkService "sillytavern" {
  port = 8000;
  image = "ghcr.io/sillytavern/sillytavern";   # multi-arch, runs on aarch64
  bypassAuth = true;                            # tailnet-only; galactica Authelia is down anyway
  exposeViaTailscale = true;                    # → chat.bat-boa.ts.net via tsnsrv
  container = {
    exposePort = 8000;
    configDir = "/home/node/app/config";        # ST's config path; mkService auto-mounts /var/data/sillytavern here
    environment = {
      SILLYTAVERN_LISTEN = "true";
      SILLYTAVERN_WHITELISTMODE = "false";       # behind reverse proxy / tailnet
      SILLYTAVERN_SECURITYOVERRIDE = "true";     # allow running with whitelist off behind a proxy
    };
    volumes = [ "/var/data/sillytavern-data:/home/node/app/data" ];  # chats, characters, entered API keys
  };
}
```

Notes / to confirm during planning:
- **`exposeViaTailscale` spelling:** confirm against `__mkService.nix` whether it
  is a top-level `mkService` arg or must be set on the produced
  `media.gateway.services.<name>.exposeViaTailscale` entry. The gateway option is
  `exposeViaTailscale` (see `modules/media/gateway.nix`).
- **Config dir mount:** `mkService` auto-mounts `${configDir}/<name>` →
  `container.configDir`. Setting `configDir = "/home/node/app/config"` maps
  `/var/data/sillytavern` → SillyTavern's config dir. The data volume is mounted
  separately at `/var/data/sillytavern-data`.
- **PUID/PGID/TZ:** injected automatically by `mkService` from `media.config`
  (5000/5000). The image honors `PUID`/`PGID`.
- **Env var override mechanism:** SillyTavern supports `SILLYTAVERN_*`
  environment variables that override `config.yaml` keys. Confirm the exact key
  names (`LISTEN`, `WHITELISTMODE`, `SECURITYOVERRIDE`) against the running image
  version during implementation; adjust if the image expects a different casing
  or a mounted `config.yaml` instead.

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
