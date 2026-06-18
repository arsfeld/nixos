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
| Routing | **Manual Caddy vhost** (not the `mkService` gateway path) | Gives the exact hostname `chat.arsfeld.one` and avoids auto-wiring the dead Authelia forward_auth; mirrors `blog.nix`/`siyuan.nix` |
| Identity provider | One-time PIN (built-in email) | No IdP integration to configure; allow-list the owner's email |
| Container / volumes / tsnsrv | **Unchanged** | This change only adds an ingress path |

## Why not the alternatives

- **`mkService` gateway path (`port` set, `bypassAuth = true`) — rejected:**
  registering a gateway service names the vhost `sillytavern.arsfeld.one`, not
  `chat.arsfeld.one`, and auto-wires `forward_auth` to
  `auth.bat-boa.ts.net` (galactica's Authelia, **down**). Disabling it with
  `bypassAuth = true` would leave an open NSFW service on the public internet
  with the wrong hostname. A manual Caddy vhost gives the exact name and no
  origin-side auth wiring.
- **Caddy basic auth / SillyTavern built-in login — rejected for this iteration:**
  both are self-contained and declarative, but auth would happen *at the origin*
  (NSFW content reachable on the public internet up to the auth prompt) rather
  than at the edge. Cloudflare Access blocks before the tunnel, so the origin is
  never exposed to unauthenticated traffic. (These remain viable fallbacks if
  Cloudflare Access is ever undesirable.)
- **Caddy JWT validation of `Cf-Access-Jwt-Assertion` — deferred:** sound
  belt-and-suspenders, but the origin is only reachable through the outbound
  tunnel, so edge auth is already sufficient. Can be added later if an
  accidental allow-all Access policy is a concern.

## Architecture

```
Public ──▶ Cloudflare edge ──[Access gate: email OTP]──▶ cloudflared tunnel
                                                              │
Tailnet ──▶ chat.bat-boa.ts.net (tsnsrv) ────────────────────┤
                                                              ▼
                                            basestar Caddy ──▶ SillyTavern :18000 (loopback)
                                                                  │
                                            text ─────────────────┼──▶ OpenRouter
                                            images ───────────────┴──▶ Stable Horde
```

The container, the loopback publish (`127.0.0.1:18000`), and the tsnsrv `chat`
node are unchanged. We add exactly one Caddy vhost and one out-of-Nix Cloudflare
Access application. The wildcard `*.arsfeld.one` tunnel ingress already routes
`chat.arsfeld.one → https://localhost` (Caddy), so cloudflared needs no change.

## Implementation

### Edit: `hosts/basestar/services/sillytavern.nix`

Append a Caddy vhost block to the existing `lib.mkMerge` list (alongside the
`mkService` container block and the `services.tsnsrv.services.chat` block):

```nix
{
  # Public, Cloudflare-Access-gated route. The wildcard *.arsfeld.one tunnel
  # ingress already lands here; auth is enforced at Cloudflare's edge, so no
  # forward_auth/bypassAuth wiring at the origin. Mirrors blog.nix/siyuan.nix.
  services.caddy.virtualHosts."chat.arsfeld.one" = {
    useACMEHost = "arsfeld.one"; # wildcard cert the gateway already provisions
    extraConfig = ''
      reverse_proxy 127.0.0.1:18000
    '';
  };
}
```

Verified facts:
- **TLS cert:** `media.gateway` provisions `security.acme.certs."arsfeld.one"`
  with `extraDomainNames = ["*.arsfeld.one"]` (`modules/media/gateway.nix`), so
  `useACMEHost = "arsfeld.one"` covers `chat.arsfeld.one`. cloudflared also runs
  with `noTLSVerify = true`, so origin cert validity is not even required.
- **Routing:** the tunnel ingress is wildcard `*.arsfeld.one → https://localhost`
  (`hosts/basestar/services/cloudflared.nix`); Caddy matches the vhost by the
  `Host: chat.arsfeld.one` header. No cloudflared edit needed.
- **No `mkService` change:** the container block stays `port = null`
  (gateway-less). We add the vhost manually instead of registering a gateway
  service, so no Authelia forward_auth is wired.
- **Same loopback port:** both tsnsrv and Caddy reverse-proxy to
  `127.0.0.1:18000`; ST already runs behind the tsnsrv proxy with
  `WHITELISTMODE=false` / `SECURITYOVERRIDE=true`, so a second proxy needs no ST
  config change.

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

Container env (`SILLYTAVERN_*`), the `/var/data/sillytavern-data` volume,
PUID/PGID, the tsnsrv `chat` node, OpenRouter/Stable Horde API keys, and the
`/var/data` backup coverage all stay as they are.

## Verification

After `just deploy basestar`:

1. Caddy reloaded cleanly; `chat.arsfeld.one` vhost is live (`systemctl status
   caddy`, no config errors).
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
