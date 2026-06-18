# SillyTavern (NSFW chat + image gen) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a single-user, Tailscale-only SillyTavern container on basestar that uses OpenRouter for text and Stable Horde for images.

**Architecture:** One gateway-less OCI container declared via the repo's `mkService` helper, published only on loopback (`127.0.0.1:18000`), and exposed to the tailnet as `chat.bat-boa.ts.net` by a manually declared `services.tsnsrv.services` node. No Caddy vhost is created, so nothing is reachable through basestar's `*.arsfeld.one` Cloudflare tunnel. The LLM and image generation run entirely on cloud APIs; basestar only hosts the lightweight Node frontend (the image is multi-arch, so it runs natively on aarch64).

**Tech Stack:** NixOS + flake-parts, `mkService` (`modules/media/__mkService.nix`), `virtualisation.oci-containers` (Docker backend), `tsnsrv`, Colmena (`just deploy`).

**Spec:** `docs/superpowers/specs/2026-06-17-sillytavern-nsfw-chat-design.md`

---

## File Structure

- **Create:** `hosts/basestar/services/sillytavern.nix` — the entire service: the `mkService` container definition plus the manual tsnsrv node. One file, one responsibility (this service), mirroring how every other basestar service is laid out (e.g. `gatus.nix`, `yarr.nix`).
- **Modify:** `hosts/basestar/services/default.nix` — add `./sillytavern.nix` to the `imports` list so it is actually loaded.

No new modules, no secrets files, no backup changes (`/var/data` is already in basestar's backrest plan).

---

## Notes for the implementer (read once)

- **Run everything from the dev shell.** Prefix commands with `nix develop -c ...` or run `nix develop` first. `just` recipes assume the dev shell.
- **basestar is aarch64 and is its own remote builder.** Local evaluation happens on this x86 machine; the actual closure builds on basestar. galactica is currently **down** — do not try to deploy or build anything there.
- **Do not hand-write `virtualisation.oci-containers` or `media.gateway.services`.** Always go through `mkService` (project rule in `CLAUDE.md`). The only thing written by hand here is the `services.tsnsrv.services.chat` node, which is the established pattern for tailnet-only access (see `hosts/basestar/services/gatus.nix:189-193`).
- **Why `port = null`:** a non-null `port` makes `mkService` register a gateway service, which generates a public `<name>.arsfeld.one` Caddy vhost served by the wildcard cloudflared tunnel. For an NSFW service that must not happen, so we publish on loopback via `extraOptions` and expose via tsnsrv instead.

---

## Task 1: Create the SillyTavern service file

**Files:**
- Create: `hosts/basestar/services/sillytavern.nix`

- [ ] **Step 1: Write the service file**

Create `hosts/basestar/services/sillytavern.nix` with exactly this content:

```nix
# SillyTavern — single-user NSFW chat + image generation frontend.
#
# Text generation uses OpenRouter; image generation uses Stable Horde.
# Both API keys are entered once in SillyTavern's UI and persist in the data
# volume (/var/data/sillytavern-data/.../secrets.json) — no sops wiring.
#
# Access is Tailscale-only: this is a gateway-less container (port = null, so
# no Caddy vhost and nothing on the public *.arsfeld.one cloudflared tunnel),
# published only on loopback and exposed to the tailnet via tsnsrv as
# chat.bat-boa.ts.net (mirrors gatus.nix).
{
  self,
  lib,
  ...
}: let
  mkService = import "${self}/modules/media/__mkService.nix" {inherit lib;};
in
  lib.mkMerge [
    (mkService "sillytavern" {
      port = null; # gateway-less: no Caddy vhost, not exposed via cloudflared
      image = "ghcr.io/sillytavern/sillytavern";
      container = {
        # ST stores config under /home/node/app/config; mkService auto-mounts
        # /var/data/sillytavern -> here.
        configDir = "/home/node/app/config";
        environment = {
          SILLYTAVERN_LISTEN = "true";
          SILLYTAVERN_WHITELISTMODE = "false";
          SILLYTAVERN_SECURITYOVERRIDE = "true";
        };
        # Chats, characters, personas, and entered API keys.
        volumes = ["/var/data/sillytavern-data:/home/node/app/data"];
        # Publish on loopback only; tsnsrv reaches the service here.
        extraOptions = ["--publish=127.0.0.1:18000:8000"];
      };
    })

    {
      # Tailnet-only access node -> chat.bat-boa.ts.net. funnel = false keeps it
      # off the public internet. tsnsrv is already enabled on basestar with a
      # default authKeyPath (hosts/basestar/services.nix).
      services.tsnsrv.services.chat = {
        toURL = "http://127.0.0.1:18000";
        funnel = false;
      };
    }
  ]
```

- [ ] **Step 2: Format the file**

Run: `nix develop -c just fmt`
Expected: completes with no error; `hosts/basestar/services/sillytavern.nix` is unchanged or only whitespace-adjusted (the CI `format.yml` check runs `alejandra`).

- [ ] **Step 3: Do NOT commit yet**

The file is not imported anywhere, so it has no effect until Task 2. Commit happens at the end of Task 2 so the repo never contains a half-wired service.

---

## Task 2: Wire the service into basestar's imports

**Files:**
- Modify: `hosts/basestar/services/default.nix`

- [ ] **Step 1: Add the import**

Edit `hosts/basestar/services/default.nix`. Add `./sillytavern.nix` to the `imports` list (alphabetical-ish placement, after `./siyuan.nix` is fine). The list should read:

```nix
{
  imports = [
    ./cloudflared.nix
    ./vault.nix
    ./yarr.nix
    ./blog.nix
    ./gatus.nix
    ./planka.nix
    ./plausible.nix
    ./radicle.nix
    ./siyuan.nix
    ./sillytavern.nix
  ];
}
```

- [ ] **Step 2: Verify the basestar config evaluates**

Run: `nix develop -c nix eval --raw .#nixosConfigurations.basestar.config.system.build.toplevel.drvPath`
Expected: prints a `/nix/store/....drv` path with no evaluation errors. (This evaluates the whole host config — it will fail loudly if the new file has a typo, an unknown option, or a bad mkService argument. It does not build the closure, so it is fast.)

- [ ] **Step 3: Verify no gateway vhost was created for sillytavern**

This guards the core security property (no public exposure). Run:

```bash
nix develop -c nix eval --json \
  '.#nixosConfigurations.basestar.config.media.gateway.services' \
  --apply 'builtins.attrNames'
```

Expected: a JSON array of service names that does **NOT** contain `"sillytavern"`. (Because `port = null`, `mkService` must not register a gateway service. If `sillytavern` appears here, the container would get a public `sillytavern.arsfeld.one` vhost — stop and fix.)

- [ ] **Step 4: Verify the tsnsrv node exists and targets loopback**

Run:

```bash
nix develop -c nix eval --json \
  '.#nixosConfigurations.basestar.config.services.tsnsrv.services.chat.toURL'
```

Expected: `"http://127.0.0.1:18000"`.

- [ ] **Step 5: Commit**

```bash
git add hosts/basestar/services/sillytavern.nix hosts/basestar/services/default.nix
git commit -m "feat(basestar): add SillyTavern NSFW chat with image generation

Gateway-less container exposed tailnet-only as chat.bat-boa.ts.net via
tsnsrv; OpenRouter for text, Stable Horde for images. API keys entered in
the UI and persisted in /var/data, so no sops wiring."
```

---

## Task 3: Build and deploy to basestar

**Files:** none (deployment only)

- [ ] **Step 1: Build the basestar closure**

Run: `nix develop -c just build basestar`
Expected: builds successfully (aarch64 closure builds on basestar as the remote builder). The new `docker-sillytavern.service` unit and the `tsnsrv-chat` unit appear in the system derivation. If the SillyTavern image reference is wrong this still succeeds (image is pulled at runtime, not build time) — image problems surface in Task 4.

- [ ] **Step 2: Confirm the loopback port is free on basestar**

Run: `ssh basestar.bat-boa.ts.net 'ss -tlnp | grep -E ":18000" || echo FREE'`
Expected: `FREE`. (If something already listens on `127.0.0.1:18000`, change `18000` to another free high port in **both** the `--publish` option and `services.tsnsrv.services.chat.toURL`, re-run Task 2 Step 2, and rebuild.)

- [ ] **Step 3: Deploy**

Run: `nix develop -c just deploy basestar`
Expected: Colmena applies the new config to basestar with no activation errors.

---

## Task 4: Runtime verification

**Files:** none (verification only)

- [ ] **Step 1: Container is running and healthy**

Run: `ssh basestar.bat-boa.ts.net 'systemctl status docker-sillytavern.service --no-pager | head -20'`
Expected: unit is `active (running)`. If it is restarting, check logs: `ssh basestar.bat-boa.ts.net 'journalctl -u docker-sillytavern.service -n 50 --no-pager'`.

- [ ] **Step 2: Service answers on loopback**

Run: `ssh basestar.bat-boa.ts.net 'curl -sS -o /dev/null -w "%{http_code}\n" http://127.0.0.1:18000/'`
Expected: `200` (SillyTavern serves its UI). A connection-refused here means the container is not listening — recheck `SILLYTAVERN_LISTEN=true` and the published port.

- [ ] **Step 3: tsnsrv node is up**

Run: `ssh basestar.bat-boa.ts.net 'systemctl status tsnsrv-chat.service --no-pager | head -20'`
Expected: `active (running)`. The first start may log a registration line; the node should appear as `chat` in the tailnet.

- [ ] **Step 4: Reachable over the tailnet**

From any tailnet device (this machine): `curl -sS -o /dev/null -w "%{http_code}\n" https://chat.bat-boa.ts.net/`
Expected: `200`. Then open `https://chat.bat-boa.ts.net` in a browser — SillyTavern's UI loads.

- [ ] **Step 5: Confirm it is NOT publicly reachable**

Run: `curl -sS -o /dev/null -w "%{http_code}\n" https://sillytavern.arsfeld.one/ ; curl -sS -o /dev/null -w "%{http_code}\n" https://chat.arsfeld.one/`
Expected: both return `404`, `530`, or a connection error — **not** `200` and not a SillyTavern page. (Confirms no public vhost leaked through the cloudflared tunnel.)

- [ ] **Step 6: Wire the cloud APIs in the UI (manual, one-time)**

In `https://chat.bat-boa.ts.net`:
1. **Text:** API Connections → Chat Completion → source **OpenRouter** (or Custom endpoint `https://openrouter.ai/api/v1`), paste the OpenRouter API key, pick an uncensored/unmoderated model, and send a test message → expect a reply.
2. **Images:** Extensions → Image Generation → source **Stable Horde** (anonymous key `0000000000`, or a free registered key for priority), then generate one image → expect an image to appear inline.

Keys persist in `/var/data/sillytavern-data` and survive restarts/redeploys.

- [ ] **Step 7: Confirm persistence path is backed up (no action, just verify)**

Run: `ssh basestar.bat-boa.ts.net 'ls -la /var/data/sillytavern /var/data/sillytavern-data'`
Expected: both directories exist, owned by uid/gid `5000`. They live under `/var/data`, which basestar's `constellation.backrest` `system` plan already backs up daily — no backup config change needed.

---

## Self-Review (completed by plan author)

- **Spec coverage:** SillyTavern frontend (Task 1) ✓; basestar host + Docker backend (Task 1/3) ✓; tailnet-only via tsnsrv `chat.bat-boa.ts.net` (Task 1, verified Task 4 Step 4) ✓; no public exposure (verified Task 2 Step 3, Task 4 Step 5) ✓; OpenRouter text + Stable Horde images (Task 4 Step 6) ✓; env-var config (Task 1) ✓; secrets in UI/data volume, no sops (Task 1, Task 4 Step 6) ✓; backup already covered (Task 4 Step 7) ✓; `watchImage` intentionally omitted (documented in spec) ✓.
- **Placeholder scan:** none — every code/command step has concrete content.
- **Type/name consistency:** loopback port `18000` is identical in `--publish` and `toURL`; container/config name `sillytavern` and tsnsrv node name `chat` are used consistently; `chat.bat-boa.ts.net` matches the `chat` node name.
