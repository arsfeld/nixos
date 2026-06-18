# SillyTavern Public Access via Cloudflare Access — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Expose the existing SillyTavern instance publicly at `chat.arsfeld.one`, authenticated at Cloudflare's edge, while keeping the tailnet-only `chat.bat-boa.ts.net` node working.

**Architecture:** Declare the whole service as a single `mkService "chat"` (the mandatory service helper) in `hosts/basestar/services/sillytavern.nix`. That one call emits the `chat.arsfeld.one` gateway vhost (`bypassAuth = true`, so no Authelia forward_auth), the `chat.bat-boa.ts.net` tsnsrv node (`tailscaleExposed = true`), and the container (host port `18000`). It reuses the wildcard `*.arsfeld.one` ACME cert and the existing wildcard cloudflared tunnel ingress. Authentication is enforced by a Cloudflare Zero Trust Access application (configured in the dashboard, outside Nix).

**Tech Stack:** NixOS, `mkService` (media gateway + containers + tsnsrv), Caddy, cloudflared tunnel, Cloudflare Zero Trust Access. No unit-test harness in this repo — "tests" are `nix eval`/`just build basestar` (Nix evaluation) and post-deploy manual verification.

**Hard rule:** every service on basestar MUST go through `mkService`. Do **not** hand-write `services.caddy.virtualHosts`, `services.tsnsrv.services`, `virtualisation.oci-containers.containers`, or `media.gateway.services` — solve any naming/routing need within `mkService` options instead.

**Spec:** `docs/superpowers/specs/2026-06-18-sillytavern-public-cloudflare-access-design.md`

---

### Task 1: Declare the service as a single `mkService "chat"`

**Files:**
- Rewrite: `hosts/basestar/services/sillytavern.nix`

**Context the engineer needs:**
- `mkService` (`modules/media/__mkService.nix`) is mandatory; everything (container, env, gateway vhost, tsnsrv node) comes from it. No manual `caddy`/`tsnsrv`/`oci-containers`/`gateway` blocks.
- The gateway derives subdomains from the **service name** (`<name>.<domain>`), so to get `chat.arsfeld.one` (and `chat.bat-boa.ts.net`) the service must be named `chat` — not `sillytavern`.
- `bypassAuth = true` omits the gateway's `forward_auth` to galactica's offline Authelia (`modules/media/__utils.nix`); edge auth (Cloudflare Access, Task 2) replaces it.
- `tailscaleExposed = true` emits the tsnsrv node, but only because a container's gateway `host` defaults to the hostname (`host == hostname`, the condition tsnsrv generation requires). Do not override `host`.
- The container is renamed `sillytavern → chat`. To preserve existing data, set `configDir = null` (skip the auto `/var/data/chat` mount) and mount the existing `/var/data/sillytavern*` paths explicitly. ST listens on `8000` internally; publish host port `18000` via `exposePort`.
- The wildcard `*.arsfeld.one` cloudflared ingress and the `*.arsfeld.one` ACME cert already exist — no cloudflared/cert changes.

- [ ] **Step 1: Replace the file contents**

Set `hosts/basestar/services/sillytavern.nix` to a single `mkService "chat"` (no `lib.mkMerge`, no manual blocks):

```nix
{
  self,
  lib,
  ...
}: let
  mkService = import "${self}/modules/media/__mkService.nix" {inherit lib;};
in
  mkService "chat" {
    port = 8000; # SillyTavern listens on 8000 inside the container
    image = "ghcr.io/sillytavern/sillytavern";
    bypassAuth = true; # auth enforced at Cloudflare's edge, not at the origin
    tailscaleExposed = true; # chat.bat-boa.ts.net
    container = {
      exposePort = 18000; # host port the gateway/tsnsrv proxy to
      configDir = null; # skip the auto /var/data/chat mount; mount real dirs below
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

(Keep the descriptive header comment explaining the rename and the two access paths.)

- [ ] **Step 2: Format**

Run: `nix develop -c just fmt`
Expected: exits 0; file alejandra-formatted, no errors.

- [ ] **Step 3: Verify the generated config by evaluation**

```bash
# vhost: must contain `reverse_proxy http://basestar:18000` and NO `forward_auth`
nix develop -c nix eval --raw '.#nixosConfigurations.basestar.config.services.caddy.virtualHosts."chat.arsfeld.one".extraConfig'
# tsnsrv node: toURL must be http://127.0.0.1:18000
nix develop -c nix eval '.#nixosConfigurations.basestar.config.services.tsnsrv.services.chat.toURL'
# container: ports ["18000:8000"], only the two /var/data/sillytavern* volumes
nix develop -c nix eval --json '.#nixosConfigurations.basestar.config.virtualisation.oci-containers.containers.chat.ports'
nix develop -c nix eval --json '.#nixosConfigurations.basestar.config.virtualisation.oci-containers.containers.chat.volumes'
```
Expected: vhost shows `reverse_proxy http://basestar:18000` with no `forward_auth`; tsnsrv `toURL = "http://127.0.0.1:18000"`; ports `["18000:8000"]`; volumes are exactly the two explicit mounts.

- [ ] **Step 4: Commit**

```bash
git add hosts/basestar/services/sillytavern.nix
git commit -m "feat(basestar): expose SillyTavern at chat.arsfeld.one behind Cloudflare Access"
```

---

### Task 2: Create the Cloudflare Access application (out-of-Nix) — ✅ DONE

**Files:** none — lives entirely in Cloudflare (accepted tradeoff per the spec). This task gates real protection: until it exists, `chat.arsfeld.one` would be an open NSFW endpoint, so it must exist **before** deploy (Task 3).

Done via the `cf` CLI (`/home/arosenfeld/.npm-global/bin/cf`, v0.0.6, OAuth-authenticated as `arsfeld@gmail.com` with `access:write`). Account context is set with `cf context set account-id 67a60cd5057ea97341c77d16f7cd3100`.

- [x] **Step 1: Create the self-hosted app + Owner allow-policy (one call)**

```bash
cf zero-trust access applications create --body '{
  "name": "SillyTavern",
  "domain": "chat.arsfeld.one",
  "type": "self_hosted",
  "session_duration": "24h",
  "policies": [
    { "name": "Owner", "decision": "allow",
      "include": [
        { "email": { "email": "arsfeld@gmail.com" } },
        { "email": { "email": "alex@rosenfeld.one" } }
      ] }
  ]
}'
```

(Validate first with `--dry-run`. Use `cf context set account-id <id>` once so the URL resolves.)

- [x] **Step 2: Identity method**

`allowed_idps: []` with no external IdP configured ⇒ Cloudflare's built-in **One-time PIN** is the login method. No extra config needed.

**Result (for reference / future JWT validation):**
- App UID: `d96b7072-6d3a-404d-82d2-6d1d6c918a22`
- AUD tag: `529b8a08f882b089712565fa06af23577bafe119abfa0e5895836b27690374a2`
- Policy `Owner` (allow) → `arsfeld@gmail.com`, `alex@rosenfeld.one`

Manage later with `cf zero-trust access applications {get,update,delete} d96b7072-6d3a-404d-82d2-6d1d6c918a22`.

---

### Task 3: Deploy and verify end-to-end

**Files:** none — deployment and manual verification.

- [ ] **Step 1: Deploy basestar**

Run: `just deploy basestar`
Expected: Colmena applies; Caddy reloads without error.

- [ ] **Step 2: Verify the container and Caddy are healthy**

Run: `ssh basestar.bat-boa.ts.net systemctl status docker-chat caddy`
Expected: both `active (running)`; no recent config-load errors in the Caddy journal. The container is now named `chat` (was `sillytavern`). Confirm prior chats/characters still appear in the UI — data survived the rename via the explicit `/var/data/sillytavern*` mounts.

- [ ] **Step 3: Verify unauthenticated public access is blocked**

From a non-tailnet device or an incognito window (not logged into Cloudflare Access), open `https://chat.arsfeld.one`.
Expected: redirected to the Cloudflare Access login page (One-time PIN prompt), **not** the SillyTavern UI. Entering a non-allow-listed email is rejected.

- [ ] **Step 4: Verify authenticated public access works**

Authenticate with the allow-listed email (enter the emailed PIN).
Expected: SillyTavern UI loads. Send one chat message (confirms SSE streaming survives the Cloudflare → tunnel → Caddy → ST chain) and generate one image (confirms the Stable Horde path). Both succeed.

- [ ] **Step 5: Verify the tailnet path still works without an Access prompt**

From a tailnet device, open `https://chat.bat-boa.ts.net`.
Expected: SillyTavern loads directly, with **no** Cloudflare Access prompt (this path bypasses Cloudflare entirely).

- [ ] **Step 6: (No commit)**

Verification only. If any step fails, the issue is configuration (Access policy, vhost, or tunnel) rather than code — re-check against the spec before changing the Nix file.

---

## Self-Review Notes

- **Spec coverage:** single `mkService "chat"` (Task 1) ↔ spec "Edit: sillytavern.nix"; Access app (Task 2) ↔ spec "Out-of-Nix: Cloudflare Zero Trust"; all spec verification items map to Task 3 steps 2–5. "Keep both" surface is verified by Task 3 step 5. No gaps.
- **Placeholder scan:** no TBD/TODO; every code/command step shows exact content or command.
- **Consistency:** `exposePort = 18000` → host publish `18000:8000`; the gateway proxies `http://basestar:18000` and the tsnsrv node `http://127.0.0.1:18000`; service name `chat` drives both `chat.arsfeld.one` and `chat.bat-boa.ts.net`; `arsfeld.one` is the cert host throughout. No manual Caddy/tsnsrv blocks remain.
