# SillyTavern public access at `chat.arsfeld.one` via Cloudflare Access — Design

**Date:** 2026-06-18
**Status:** Approved, pending implementation plan
**Target host:** basestar (aarch64-linux)
**Builds on:** [2026-06-17 SillyTavern NSFW chat design](2026-06-17-sillytavern-nsfw-chat-design.md)

## Goal

Expose the existing single-user SillyTavern instance publicly at
`chat.arsfeld.one`, authenticated, **without** depending on galactica (its
Authelia is offline). Keep the existing tailnet-only node working as-is.

The original SillyTavern design made the service Tailscale-only precisely
because (a) basestar's wildcard cloudflared tunnel (`*.arsfeld.one → localhost`)
makes any Caddy vhost publicly reachable, and (b) the gateway's normal auth
forwards to galactica's Authelia, which is down. This design reverses (a)
deliberately — we *want* public access — and solves (b) by authenticating at
Cloudflare's edge instead of at the origin.

## Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Auth mechanism | **Cloudflare Access** (Zero Trust), email one-time PIN | Gates at the edge before traffic reaches basestar; no galactica/Authelia dependency; origin never sees unauthenticated requests |
| Access surface | **Keep both** paths | `chat.bat-boa.ts.net` (tailnet, trusted, no auth) **and** `chat.arsfeld.one` (public, Access-gated) |
| Defense depth | **Edge auth only** | Origin is reachable only via the outbound-only tunnel, so Cloudflare is the sole ingress; no Caddy JWT validation needed |
| Routing | **Single `mkService "chat"`** (the mandatory service helper) | One declaration emits the `chat.arsfeld.one` gateway vhost, the `chat.bat-boa.ts.net` tsnsrv node, and the container; no hand-written Caddy/tsnsrv/oci blocks |
| Origin-side auth | `bypassAuth = true` | Omits the gateway's `forward_auth` to galactica's offline Authelia; auth is enforced at Cloudflare's edge instead |
| Identity provider | One-time PIN (built-in email) | No IdP integration to configure; allow-list the owner's email |
| Service name | `chat` (was `sillytavern`) | The gateway derives subdomains from the service name, so the service is named `chat`; existing `/var/data/sillytavern*` data is mounted explicitly to survive the rename |

## Why not the alternatives

- **Hand-written `services.caddy.virtualHosts` / `services.tsnsrv.services`
  blocks — forbidden:** `mkService` is the mandatory and only way to declare a
  service on basestar (CLAUDE.md). The naming concern that once argued for a
  manual vhost (the gateway derives the subdomain from the service name) is
  solved *within* mkService by naming the service `chat`. The Authelia concern is
  solved by `bypassAuth = true`, which omits the `forward_auth` block entirely
  (`modules/media/__utils.nix`). So the full ingress — vhost, tsnsrv node, and
  container — comes from one `mkService "chat"` call with no manual blocks.
- **Naming the service `sillytavern` (vhost `sillytavern.arsfeld.one`) —
  rejected:** the desired public hostname is `chat.arsfeld.one`. Since the
  gateway emits `<service-name>.<domain>`, the service is named `chat`; the
  container's `/var/data/sillytavern*` data is mounted explicitly so the rename
  loses nothing.
- **Caddy basic auth / SillyTavern built-in login — rejected for this iteration:**
  both are self-contained, but auth would happen *at the origin* (NSFW content
  reachable on the public internet up to the auth prompt) rather than at the
  edge. Cloudflare Access blocks before the tunnel, so the origin is never
  exposed to unauthenticated traffic. (These remain viable fallbacks if
  Cloudflare Access is ever undesirable.)
- **Caddy JWT validation of `Cf-Access-Jwt-Assertion` — deferred:** sound
  belt-and-suspenders, but the origin is only reachable through the outbound
  tunnel, so edge auth is already sufficient. Can be added later if an
  accidental allow-all Access policy is a concern.

## Architecture

```
Public ──▶ Cloudflare edge ──[Access gate: email OTP]──▶ cloudflared tunnel
                                                              │
                                            basestar Caddy (chat.arsfeld.one)
                                                              │
Tailnet ──▶ chat.bat-boa.ts.net (tsnsrv) ─────────────────────┤
                                                              ▼
                                            "chat" container (basestar :18000)
                                                                  │
                                            text ─────────────────┼──▶ OpenRouter
                                            images ───────────────┴──▶ Stable Horde
```

A single `mkService "chat"` emits all three: the `chat.arsfeld.one` gateway
vhost, the `chat.bat-boa.ts.net` tsnsrv node, and the container (host port
`18000`). The wildcard `*.arsfeld.one` tunnel ingress already routes
`chat.arsfeld.one → https://localhost` (Caddy), so cloudflared needs no change.
The only other piece is one out-of-Nix Cloudflare Access application.

## Implementation

### Edit: `hosts/basestar/services/sillytavern.nix`

Replace the previous three-block layout (gateway-less container + manual tsnsrv +
manual vhost) with a single `mkService "chat"`:

```nix
mkService "chat" {
  port = 8000;                                 # ST listens on 8000 in-container
  image = "ghcr.io/sillytavern/sillytavern";
  bypassAuth = true;                           # edge auth only; omit Authelia forward_auth
  tailscaleExposed = true;                     # chat.bat-boa.ts.net
  container = {
    exposePort = 18000;                        # host port gateway/tsnsrv proxy to
    configDir = null;                          # skip auto /var/data/chat mount
    environment = {
      SILLYTAVERN_LISTEN = "true";
      SILLYTAVERN_WHITELISTMODE = "false";
      SILLYTAVERN_SECURITYOVERRIDE = "true";
    };
    volumes = [
      "/var/data/sillytavern:/home/node/app/config"
      "/var/data/sillytavern-data:/home/node/app/data"
    ];
  };
}
```

Verified facts (by `nix eval` against `nixosConfigurations.basestar`):
- **Gateway vhost:** `chat.arsfeld.one` is generated with
  `reverse_proxy http://basestar:18000` and **no** `forward_auth` block
  (`bypassAuth = true` omits it — `modules/media/__utils.nix`). `useACMEHost`
  resolves to the `*.arsfeld.one` wildcard cert the gateway provisions
  (`security.acme.certs."arsfeld.one"`). cloudflared runs `noTLSVerify = true`,
  so origin cert validity is not even required.
- **Tailnet node:** `services.tsnsrv.services.chat.toURL = http://127.0.0.1:18000`
  is emitted because `tailscaleExposed` sets `exposeViaTailscale` and the
  container's gateway `host` defaults to the hostname (`host == hostname`, the
  condition tsnsrv generation requires).
- **Container:** OCI container is named `chat`, publishes `18000:8000`, and mounts
  only the two explicit `/var/data/sillytavern*` paths (no stray `/var/data/chat`
  mount, since `configDir = null`). PUID/PGID/TZ are injected by `containers.nix`.
- **Routing:** the tunnel ingress is wildcard `*.arsfeld.one → https://localhost`
  (`hosts/basestar/services/cloudflared.nix`); Caddy matches by the
  `Host: chat.arsfeld.one` header. No cloudflared edit needed.
- **Data preserved across the rename:** the container moves from `sillytavern` to
  `chat`, but both bind-mount the same host paths, so chats/characters/API keys
  in `/var/data/sillytavern-data` and config in `/var/data/sillytavern` are
  retained. `WHITELISTMODE=false` / `SECURITYOVERRIDE=true` keep ST happy behind
  the proxy.

### Out-of-Nix: Cloudflare Zero Trust — Access application

This is the one piece not managed in the repo (the accepted tradeoff of choosing
Cloudflare Access). In the Cloudflare Zero Trust dashboard:

1. **Access → Applications → Add an application → Self-hosted.**
2. Application name: `SillyTavern`; Application domain: `chat.arsfeld.one`.
3. Identity providers: **One-time PIN** (built-in email; no external IdP).
4. Session duration: owner's preference (e.g. 24 h–30 d).
5. **Policy:** Action *Allow*; Include → **Emails** → the owner's email
   address(es).
6. Save. Access protects `chat.arsfeld.one` immediately because the route is
   served through the tunnel.

No secrets enter the Nix repo; the Access policy lives entirely in Cloudflare.

### Unchanged

Container env (`SILLYTAVERN_*`), the `/var/data/sillytavern` config and
`/var/data/sillytavern-data` data paths, OpenRouter/Stable Horde API keys, and
the `/var/data` backup coverage all stay as they are. The container/unit is
renamed `sillytavern → chat`, but the data on disk is untouched.

## Verification

After `just deploy basestar`:

1. The `chat` container is healthy (`systemctl status docker-chat`, or
   `docker ps`), and Caddy reloaded cleanly with the `chat.arsfeld.one` vhost
   (`systemctl status caddy`, no config errors). Confirm prior chats/characters
   still appear in the UI (data survived the rename).
2. From a non-tailnet device or incognito window, open `https://chat.arsfeld.one`
   → redirected to the Cloudflare Access login. A non-allow-listed email is
   rejected.
3. After authenticating with the allow-listed email, SillyTavern loads. Send a
   chat message (SSE streaming) and generate one image — both cloud paths work
   through the proxy chain.
4. `https://chat.bat-boa.ts.net` still loads directly from a tailnet device with
   **no** Access prompt.

## Out of scope (YAGNI)

- Caddy-side `Cf-Access-Jwt-Assertion` validation (deferrable defense-in-depth).
- Declarative management of the Cloudflare Access app (would need Terraform /
  Cloudflare API; repo is pure Nix today).
- Multi-user accounts, Authelia, or any galactica-dependent auth.
- External IdP (Google/GitHub) for Access — email OTP is sufficient for a single
  user; switchable later in the Access dashboard with no Nix change.
