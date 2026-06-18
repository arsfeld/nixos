# SillyTavern Public Access via Cloudflare Access — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Expose the existing SillyTavern instance publicly at `chat.arsfeld.one`, authenticated at Cloudflare's edge, while keeping the tailnet-only `chat.bat-boa.ts.net` node working.

**Architecture:** Add one manual Caddy vhost (`chat.arsfeld.one → 127.0.0.1:18000`) to the existing `hosts/basestar/services/sillytavern.nix`, reusing the wildcard `*.arsfeld.one` ACME cert and the existing wildcard cloudflared tunnel ingress. Authentication is enforced by a Cloudflare Zero Trust Access application (configured in the dashboard, outside Nix). The SillyTavern container, its loopback publish, and the tsnsrv node are unchanged.

**Tech Stack:** NixOS, Caddy (`services.caddy.virtualHosts`), cloudflared tunnel, Cloudflare Zero Trust Access. No unit-test harness in this repo — "tests" are `just build basestar` (Nix evaluation + build) and post-deploy manual verification.

**Spec:** `docs/superpowers/specs/2026-06-18-sillytavern-public-cloudflare-access-design.md`

---

### Task 1: Add the `chat.arsfeld.one` Caddy vhost

**Files:**
- Modify: `hosts/basestar/services/sillytavern.nix` (append a block to the existing `lib.mkMerge` list)

**Context the engineer needs:**
- The file currently has a `lib.mkMerge [ ... ]` with two elements: a `(mkService "sillytavern" {...})` block and a `{ services.tsnsrv.services.chat = {...}; }` block. You are adding a **third** element — a Caddy vhost attrset. Do **not** modify the container's `port = null` or convert it to a gateway service; that would name the vhost `sillytavern.arsfeld.one` and auto-wire the offline Authelia.
- The wildcard cert is already provisioned by `media.gateway` as `security.acme.certs."arsfeld.one"` with `extraDomainNames = ["*.arsfeld.one"]`, so `useACMEHost = "arsfeld.one"` is valid.
- The cloudflared tunnel ingress is already wildcard (`*.arsfeld.one → https://localhost`), so no cloudflared change is needed. Caddy routes by the `Host: chat.arsfeld.one` header.
- The pattern mirrors `hosts/basestar/services/siyuan.nix:97` and `blog.nix:78` (both use `services.caddy.virtualHosts.<host>` with `useACMEHost`).

- [ ] **Step 1: Add the vhost block**

Open `hosts/basestar/services/sillytavern.nix`. Inside the `lib.mkMerge [ ... ]` list, after the closing `}` of the existing `services.tsnsrv.services.chat` block (the last element, currently around line 46), add a new element. The list should end like this:

```nix
    {
      # Tailnet-only access node -> chat.bat-boa.ts.net. funnel = false keeps it
      # off the public internet. tsnsrv is already enabled on basestar with a
      # default authKeyPath (hosts/basestar/services.nix).
      services.tsnsrv.services.chat = {
        toURL = "http://127.0.0.1:18000";
        funnel = false;
      };
    }

    {
      # Public, Cloudflare-Access-gated route at chat.arsfeld.one. The wildcard
      # *.arsfeld.one cloudflared tunnel ingress already lands on this Caddy, so
      # no tunnel change is needed. Authentication is enforced at Cloudflare's
      # edge by a Zero Trust Access app, so there is NO forward_auth/bypassAuth
      # wiring here (galactica's Authelia is offline by design). Mirrors the
      # arsfeld.dev vhosts in blog.nix / siyuan.nix.
      services.caddy.virtualHosts."chat.arsfeld.one" = {
        useACMEHost = "arsfeld.one"; # wildcard cert provisioned by media.gateway
        extraConfig = ''
          reverse_proxy 127.0.0.1:18000
        '';
      };
    }
  ]
```

Make sure the new block is a sibling element inside the `mkMerge` list (a `{ ... }` separated by whitespace from the previous element), and that the list's closing `]` follows it.

- [ ] **Step 2: Format**

Run: `just fmt`
Expected: exits 0; `hosts/basestar/services/sillytavern.nix` reformatted by alejandra with no errors.

- [ ] **Step 3: Build basestar to verify the config evaluates**

Run: `just build basestar`
Expected: build succeeds. A successful evaluation proves the new vhost attrset merges cleanly and `useACMEHost = "arsfeld.one"` references an existing ACME cert. If evaluation fails with an `arsfeld.one` ACME-cert-not-found error, stop — the gateway is expected to provide it; re-read `modules/media/gateway.nix:193`.

- [ ] **Step 4: Commit**

```bash
git add hosts/basestar/services/sillytavern.nix
git commit -m "feat(basestar): expose SillyTavern at chat.arsfeld.one behind Cloudflare Access"
```

---

### Task 2: Create the Cloudflare Access application (out-of-Nix)

**Files:** none — this is a manual step in the Cloudflare Zero Trust dashboard. It is **not** managed in the repo (accepted tradeoff per the spec). This task gates real protection: until it exists, `chat.arsfeld.one` would be an open NSFW endpoint, so do it **before or immediately at** deploy, and verify in Task 3 that an unauthenticated request is actually blocked.

- [ ] **Step 1: Add the Access application**

In the Cloudflare dashboard for the account owning `arsfeld.one`: **Zero Trust → Access → Applications → Add an application → Self-hosted.**
- Application name: `SillyTavern`
- Session duration: owner's preference (e.g. `24h` or `1 month`)
- Public hostname / Application domain: subdomain `chat`, domain `arsfeld.one` (i.e. `chat.arsfeld.one`)

- [ ] **Step 2: Set the identity method**

In the application's **Authentication** settings, enable **One-time PIN** (built-in email login — no external IdP integration required).

- [ ] **Step 3: Add the allow policy**

Add a policy:
- Policy name: `Owner`
- Action: **Allow**
- Include → selector **Emails** → enter the owner's email address(es).

Save the application. Cloudflare Access now protects `chat.arsfeld.one` because the route is served through the tunnel.

- [ ] **Step 4: (No commit)**

Nothing to commit — this lives entirely in Cloudflare. Record in the deploy notes / commit message of Task 1 that the Access app must exist.

---

### Task 3: Deploy and verify end-to-end

**Files:** none — deployment and manual verification.

- [ ] **Step 1: Deploy basestar**

Run: `just deploy basestar`
Expected: Colmena applies; Caddy reloads without error.

- [ ] **Step 2: Verify Caddy is healthy and serving the vhost**

Run: `ssh basestar.bat-boa.ts.net systemctl status caddy`
Expected: `active (running)`, no recent config-load errors in the journal.

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

- **Spec coverage:** Caddy vhost (Task 1) ↔ spec "Edit: sillytavern.nix"; Access app (Task 2) ↔ spec "Out-of-Nix: Cloudflare Zero Trust"; all four spec verification items map to Task 3 steps 2–5. "Keep both" surface is verified by Task 3 step 5. No gaps.
- **Placeholder scan:** no TBD/TODO; every code/command step shows exact content or command.
- **Consistency:** loopback port `127.0.0.1:18000` matches the container's existing `--publish=127.0.0.1:18000:8000`; hostname `chat.arsfeld.one` and cert host `arsfeld.one` are used consistently throughout.
