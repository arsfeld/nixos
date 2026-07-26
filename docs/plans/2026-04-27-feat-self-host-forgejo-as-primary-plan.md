---
title: Self-Host Forgejo as Primary Repo Location with Forgejo Actions CI
type: feat
status: active
date: 2026-04-27
origin: docs/brainstorms/2026-04-27-self-host-forgejo-brainstorm.md
---

# Self-Host Forgejo as Primary Repo Location with Forgejo Actions CI

> **Origin brainstorm:** [docs/brainstorms/2026-04-27-self-host-forgejo-brainstorm.md](../brainstorms/2026-04-27-self-host-forgejo-brainstorm.md). Carried-forward decisions: (1) primary on storage with GitHub mirror; (2) Forgejo over Gitea/GitLab; (3) Forgejo Actions runners on host system; (4) two labeled runners (storage x86_64, basestar aarch64); (5) Authelia OIDC for SSO; (6) hard cutover.

## Enhancement Summary (post-deepen pass)

**Deepened on:** 2026-04-27
**Reviews applied:** architecture, security, simplicity, pattern, data-integrity, deployment Go/No-Go, performance, plus targeted best-practices research on systemd `ExecStartPost`/`Type=notify` patterns
**Findings:** 50+ items; full punch list in the [Deep Review Findings appendix](#deep-review-findings) at the end of this plan.

### Critical Corrections to Apply Before Phase 1

1. **Backup — keep it simple (per user feedback).** Just ensure `/var/lib` is included in the existing system backup paths on storage. No SQLite `.backup` pre-hook, no `systemctl stop forgejo` quiescing window, no per-service hooks. Hot snapshot of `/var/lib/forgejo` (via the existing Backrest plan covering `/var`) is fine: SQLite recovers cleanly from minor inconsistencies on restore, and the live GitHub mirror is the real RPO-minutes backup for git refs. Worst case after a restore is `forgejo doctor check --all` repairs metadata. Tooling is **Backrest+restic** (not rustic — typo corrected throughout).

2. **Manual one-time bootstrap (per user feedback).** Admin user creation, OAuth source registration, and push-mirror configuration are **one-time manual steps via SSH/CLI or web UI**, not declarative systemd units. Solo personal repo doesn't justify the ceremony. Trade-off accepted: if storage is rebuilt from scratch, SSH in after Phase 1 deploys Forgejo and run ~3 commands. Snapshot restore preserves admin user, OAuth source, and mirror config (all live in SQLite). Bootstrap-admin-password file (and its rotation/backup hygiene problems) deleted entirely.

3. **GitHub stays public, not archived (per user feedback).** Mirror is force-push: any direct GitHub push gets clobbered cleanly on the next Forgejo push. Public discoverability preserved. No Phase 6.8 archive step.

4. **Gateway entry needs `settings.bypassAuth = true`.** Forgejo runs its own auth (Authelia OIDC + form-auth break-glass). Without `bypassAuth`, Caddy's `forward_auth` runs Authelia in front of Forgejo, breaking the OIDC callback flow with a 401. Compare `hosts/storage/services/transmission-vpn.nix:26` and `auth.nix:125` for the existing convention.

5. **`vars.domain` instead of literal `"arsfeld.one"`** in the forgejo.nix sketch — `let vars = config.media.config; in { ... DOMAIN = "git.${vars.domain}"; ... }`. Existing pattern at `develop.nix:6`, `auth.nix:7-12`.

6. **basestar runner capacity 4 → 2.** basestar has 4 cores / 24 GB RAM. Capacity 4 saturates eval+build memory; 2 jobs × 2 cores out-throughputs 4 × 1. Add `MemoryHigh = "16G"` on the runner slice. Storage capacity 3 stays but with `MemoryHigh = "12G"` to leave headroom for co-tenants (Plex, *arr).

7. **Walltime target tightened to ≤50 min P50, ≤75 min P95** (was ≤90 min). Native execution should be **faster** than QEMU-emulated GHA, not slower. Measure from run #4 onward (cold-cache pre-warm caveat).

8. **Mirror-lag Gatus check moved to Phase 6, not Phase 7+.** "PAT expired, mirror silently broken for weeks" is the dominant operational risk. A Gatus check comparing Forgejo HEAD ↔ GitHub HEAD every 5 min (alert if >5 min divergence) must ship with cutover.

9. **GitHub PAT scope reduction Phase 6.1.** `Workflows: write` is needed exactly once — for the cutover commit deleting `.github/workflows/`. After verification, regenerate as `Contents: write` only.

10. **Action `uses:` pinned to commit SHAs**, not tags. `https://data.forgejo.org/actions/checkout@<sha>` not `@v4`. Tag-move attacks against the action proxy are mitigated.

11. **Forgejo Actions retention** — add `actions.LOG_RETENTION = "30d"`, `actions.ARTIFACT_RETENTION_DAYS = 14`, `cron.cleanup_actions.ENABLED = "true"`, monthly `VACUUM` cron. Without these, SQLite + `actions_log/` grow unbounded.

### Items Documented in Appendix (apply during implementation)

The remaining ~40 review findings live in the [Deep Review Findings appendix](#deep-review-findings) at the end of the plan, marked **APPLIED** or **PENDING** by category. Notable categories: post-Phase-2 admin-password rotation, OIDC `userinfo_signed_response_alg` hardening, runner-config DRY into `modules/constellation/forgejo-runner.nix`, file rename `forgejo.nix` → `git.nix` for naming consistency, IO-weight tuning, runner-cache tmpfiles cleanup.

### Deliberately Not Applied (despite simplicity-reviewer recommendations)

- **Six phases preserved.** Merging phases obscures chicken-and-egg dependencies that make migration safe; clean Go/No-Go gates per phase outweigh the line-count savings.
- **Token rotation procedures kept.** Security review confirmed the GitHub PAT rotation has a non-obvious gotcha (API can't patch `remote_password` — must DELETE+POST). Documenting this avoids a future emergency.
- **DR runbook trimmed but kept.** Cut the "nuclear" scenario (replaced with one paragraph pointing at the GitHub mirror). Kept warm-restart, restic-restore, and Authelia-outage scenarios — multiple reviewers flagged restore-correctness as load-bearing.

## Overview

Move the primary location of this NixOS config repo from GitHub to a self-hosted **Forgejo** instance running on the `storage` host, with self-hosted **Forgejo Actions** runners on `storage` (x86_64) and `basestar` (aarch64). GitHub becomes a read-only push-mirror, automatically updated from Forgejo on every commit to `master`.

Reachable at **`git.arsfeld.one`** via the existing storage cloudflared wildcard tunnel. CI replicates today's `build.yml` (closures → Attic) plus `nix flake check` and `just fmt --check`. Auto-deploy explicitly out of scope; the weekly flake-input bumper is **deferred to a follow-up phase** so the initial migration is smaller.

**This is not greenfield.** Local research surfaced that Forgejo is already ~80% scaffolded: `services.forgejo` is enabled (but unused) in `hosts/storage/services/develop.nix`; an aarch64 runner is scaffolded but disabled in `hosts/basestar/services/development.nix`; the OIDC client secret already exists in sops. The plan therefore frames this as **finish-and-cutover**, not stand-up.

## Problem Statement / Motivation

Today the canonical copy of this repo lives at `github.com/arsfeld/nixos`, with CI in GitHub Actions building host closures and pushing to the existing Attic binary cache at `attic.arsfeld.dev`. The user wants the canonical copy at home, on hardware they control, with CI that:

- Has direct access to the host `/nix` store (no install-Nix-every-run dance)
- Runs on the same NixOS that actually deploys these closures (no QEMU-emulated aarch64 builds)
- Doesn't depend on GitHub uptime for personal infra to merge changes

GitHub stays in the picture as a **public mirror and live off-site backup** — discoverability and DR without the dependency on a third party for authoritative writes.

## Proposed Solution

### Architecture

```
┌──────────────────────────────────────────────────────────────────────┐
│                          storage (x86_64)                            │
│                                                                      │
│  ┌─────────────────┐    ┌──────────────────┐   ┌──────────────────┐ │
│  │ Forgejo (LTS)   │◄───│ Caddy (gateway)  │◄──│  cloudflared     │ │
│  │ :3001 + :2222   │    │ git.arsfeld.one  │   │  *.arsfeld.one   │ │
│  └────────┬────────┘    └────────┬─────────┘   └──────────────────┘ │
│           │                      │                                   │
│  ┌────────▼────────┐    ┌────────▼─────────┐                        │
│  │ Authelia OIDC   │◄───│ forward_auth     │                        │
│  │ + LLDAP         │    │ (web UI only)    │                        │
│  └─────────────────┘    └──────────────────┘                        │
│                                                                      │
│  ┌──────────────────────────────────────────────┐                   │
│  │ forgejo-runner (storage-x86_64)              │                   │
│  │ labels: [x86_64-linux:host]                  │                   │
│  │ executor: host (access to /nix store)        │                   │
│  └──────────────────────────────────────────────┘                   │
│                                                                      │
│  /var/lib/forgejo (state) ──► rustic daily ──► hetzner + pegasus    │
└──────────────────────────────────────────────────────────────────────┘
                                    │
                  ssh+tailscale     │   https+pat
                                    ▼
┌──────────────────────────────────────────────────────────────────────┐
│                      basestar (aarch64)                              │
│  ┌──────────────────────────────────────────────┐                   │
│  │ forgejo-runner (basestar-aarch64)            │                   │
│  │ labels: [aarch64-linux:host]                 │                   │
│  └──────────────────────────────────────────────┘                   │
└──────────────────────────────────────────────────────────────────────┘

      Forgejo push-mirror ───►   github.com/arsfeld/nixos  (archived/RO)
```

### Key Design Decisions

| Decision | Choice | Why |
|---|---|---|
| Forgejo package | `pkgs.forgejo-lts` | LTS line is more stable for source-of-truth infra; v15.0 LTS released 2026-04-16, nixpkgs at 14.x and lagging by ~2 weeks |
| Database | SQLite | Solo user, low write volume; one less moving part |
| State dir | `/var/lib/forgejo` (module default) | Avoid relocating defaults; align backup target to the canonical path. Brainstorm's `/var/data/forgejo` proposal **rejected** — buys nothing |
| Web URL | `git.arsfeld.one` | Brainstorm preference; renames the existing `forgejo.arsfeld.one` for a shorter URL |
| SSH | Forgejo built-in SSH on `:2222`, listening on `tailscale0` only | Tailscale-only push/pull surface; cloudflared serves HTTPS+PAT for fresh laptops |
| OIDC | Authelia (LLDAP-backed) | Same pattern as every other internal service. Authelia clients live in the `authelia-secrets` sops blob (existing convention) — Forgejo joins as the first declarative client |
| Admin role | Promote single user manually (drop `forgejo-admins` group) | LLDAP group seeding isn't declarative in this repo; one-user setup doesn't justify the ceremony |
| Runner executor | Host mode (`host` executor) | Direct `/nix` access; trade-off accepted because this is single-tenant and never builds outside contributor PRs |
| Runner capacity | basestar=4, storage=3 | Match arch-specific matrix-build counts (4 aarch64 hosts, 3 x86_64 hosts) so wallclock isn't bottlenecked |
| Mirror direction | Forgejo → GitHub, sync_on_commit, force-push | Brainstorm choice; GitHub ends up archived to prevent reverse-direction accidents |
| Workflow path | `.forgejo/workflows/*.yaml` | Native path; rename in cutover commit makes it legible in git log |
| CI scope | build + flake check + format check | Auto-deploy is OOS; weekly flake bumper deferred to a Phase 7 follow-up |
| Cutover | Hard | Verify on feature branch first, then single cutover commit |

### File-Level Changes (Summary)

**New:**
- `hosts/storage/services/forgejo.nix` — Forgejo server config + bootstrap admin + push-mirror oneshot
- `hosts/storage/services/forgejo-runner.nix` — x86_64 runner instance
- `.forgejo/workflows/build.yaml` — host closure builds → Attic
- `.forgejo/workflows/check.yaml` — `nix flake check` + `just fmt --check`

**Modified:**
- `hosts/storage/services/develop.nix` — strip out Forgejo block (moved to its own file); keep code-server only
- `hosts/storage/services/default.nix` — add `forgejo.nix` + `forgejo-runner.nix` imports
- `hosts/basestar/services/development.nix` — flip runner to `enable = true`, bump capacity, rename
- `secrets/sops/storage.yaml` — populate `forgejo-oidc-secret`; add `forgejo-github-mirror-pat`; embed Authelia OIDC client (`forgejo` entry with hashed secret) into `authelia-secrets`
- `secrets/sops/basestar.yaml` — populate `forgejo-runner-token` after Phase 1
- `CLAUDE.md` — note Forgejo as primary; update CI/CD section

**Deleted (in cutover commit):**
- `.github/workflows/build.yml`
- `.github/workflows/format.yml`
- `.github/workflows/update.yml` (or moved to Phase 7 Forgejo workflow)

## Technical Approach

### Implementation Phases

The bootstrap has **chicken-and-egg dependencies** (Forgejo must be running before runner tokens can be generated; Authelia client must exist before Forgejo OIDC consumer can be configured; mirror needs both repos to exist with a PAT). The phasing below makes those dependencies linear.

---

#### Phase 1: Stand up Forgejo with declarative bootstrap admin

**Goal:** Forgejo reachable at `https://git.arsfeld.one`, signed in as a local admin user, with Authelia OIDC configured but unused. **No runners, no mirror yet.**

**Tasks:**

1. Create `hosts/storage/services/forgejo.nix` (see [forgejo.nix sketch](#forgejonix-sketch) below). Move the Forgejo block out of `develop.nix`.
2. Set `services.forgejo.package = pkgs.forgejo-lts;`.
3. Set `services.forgejo.stateDir = "/var/lib/forgejo";` explicitly.
4. Pin `users.users.forgejo` with a stable UID + group (avoid sops `chown` race on first activation — see [Edge case #6](#edge-cases) in SpecFlow analysis).
5. Configure SSH:
   - `[server] START_SSH_SERVER = true`
   - `[server] SSH_PORT = 2222`
   - `[server] SSH_LISTEN_HOST = <tailscale-ip-of-storage>`  (or use `tailscale0` interface address resolution at activation time)
6. Disable LFS explicitly: `services.forgejo.lfs.enable = false;`.
7. Drop the broken `WHITELISTED_URIS` setting (it's the wrong setting for OAuth2 — applies to legacy OpenID 2.0).
8. Set `services.forgejo.settings.service.DISABLE_REGISTRATION = true;` and remove `ALLOW_ONLY_EXTERNAL_REGISTRATION` (we'll register through OIDC in Phase 2; keep `false` until then so the bootstrap admin can log in via password).
9. Update `media.gateway.services` entry: rename `forgejo` → `git`, set `settings.funnel = false` (cloudflared handles ingress; Funnel widens attack surface unnecessarily).
10. Add `services.forgejo.secrets.oauth2.JWT_SECRET = config.sops.secrets.forgejo-jwt-secret.path;` and create the secret in sops.
11. **Create the admin user manually after first deploy** (one-time):
    ```bash
    ssh storage 'sudo -u forgejo \
      GITEA_WORK_DIR=/var/lib/forgejo GITEA_CUSTOM=/var/lib/forgejo/custom \
      forgejo admin user create \
        --admin --username arosenfeld --email alexandrer@accessnewswire.com \
        --random-password'
    # Save the printed password in your password manager.
    ```

12. **Confirm `/var/lib` is in the existing system backup paths** (`hosts/storage/backup/backrest-client.nix`). The local-system Backrest plan already covers `/var` (i.e., `/var/lib/forgejo` rides along automatically). No per-service hook, no SQLite `.backup`, no quiescing — hot snapshot is fine for solo personal use; the live GitHub mirror covers refs at sub-minute RPO. **Do verify** that `/var/lib` is included in the `hetzner` and `pegasus` plans too (currently those target only `/home` and `/mnt/storage` per `backrest-client.nix:117-181`); add `/var/lib` to their `paths` if not already there.
13. Deploy: `just deploy storage`.
14. Verify:
    - `curl https://git.arsfeld.one/api/healthz` returns OK
    - Sign in with the manually-set admin password (from your password manager) succeeds; account has admin role
    - Sign in via web with `arosenfeld` / `<password>` — confirm admin status
    - `git ls-remote git@storage.bat-boa.ts.net:2222:arosenfeld/test.git` (after creating an empty test repo via web) returns 0 over Tailscale SSH

**Success criteria:**
- Forgejo healthy at `git.arsfeld.one` over HTTPS
- Local admin login works (manually-created user, password in password manager)
- SSH push/pull works over Tailscale
- Backup of `/var/lib/forgejo` runs without errors on the next scheduled restic run

**Estimated effort:** half day

---

#### Phase 2: Wire up Authelia OIDC SSO

**Goal:** Sign in to Forgejo via Authelia → LLDAP. The bootstrap admin gets linked to the OIDC user by email.

**Tasks:**

1. Generate a strong cleartext OIDC client secret:
   ```bash
   nix run nixpkgs#openssl -- rand -hex 32
   ```
2. Hash it for Authelia:
   ```bash
   nix run nixpkgs#authelia -- crypto hash generate pbkdf2 --variant sha512 --iterations 310000
   ```
3. Open `secrets/sops/storage.yaml` (sops is fully automated — no interactive editing fuss):
   - Set `forgejo-oidc-secret: <cleartext>` (already declared, currently empty/placeholder)
   - Edit the `authelia-secrets` blob to add a new client under `identity_providers.oidc.clients`:
     ```yaml
     - client_id: forgejo
       client_name: Forgejo
       client_secret: '$pbkdf2-sha512$310000$...'  # the hashed value
       public: false
       authorization_policy: two_factor
       redirect_uris:
         - https://git.arsfeld.one/user/oauth2/authelia/callback
       scopes: [openid, profile, email]
       grant_types: [authorization_code]
       response_types: [code]
       token_endpoint_auth_method: client_secret_basic
       userinfo_signed_response_alg: none
       require_pkce: true
       pkce_challenge_method: S256
       consent_mode: pre-configured
       pre_configured_consent_duration: 1 month
     ```
4. **Register the Forgejo OAuth2 source manually** (one-time, after Authelia restarts with the new client):
   ```bash
   ssh storage 'SECRET=$(sudo cat /run/secrets/forgejo-oidc-secret) && \
     sudo -u forgejo \
       GITEA_WORK_DIR=/var/lib/forgejo GITEA_CUSTOM=/var/lib/forgejo/custom \
       forgejo admin auth add-oauth \
         --provider=openidConnect \
         --name=authelia \
         --key=forgejo \
         --secret="$SECRET" \
         --auto-discover-url=https://auth.arsfeld.one/.well-known/openid-configuration \
         --scopes="openid email profile" \
         --skip-local-2fa'
   ```
   Or click through Site Administration → Authentication Sources in the web UI. Either way runs once.
5. Update Forgejo settings (declarative, in `forgejo.nix`):
   - `settings.oauth2_client.ENABLE_AUTO_REGISTRATION = true;` (already set)
   - `settings.oauth2_client.ACCOUNT_LINKING = "auto";` (already set — links by email)
   - `settings.service.ALLOW_ONLY_EXTERNAL_REGISTRATION = true;` (re-enable now that OIDC exists)
6. Deploy storage → Authelia restarts with the new client → run the manual `forgejo admin auth add-oauth` from step 4.
7. Verify:
   - Web sign-in via Authelia button works
   - Account links by email to existing `arosenfeld` admin (not a duplicate)
   - Authelia stop test: `systemctl stop authelia` → Forgejo web SSO unavailable but **git over SSH still works**

**Success criteria:**
- Authelia sign-in works
- The OIDC user IS the admin (verified by visiting `/-/admin`)
- The manually-set admin password (from Phase 1) remains usable as break-glass form-auth login

**Estimated effort:** half day

---

#### Phase 3: Push initial repo history into Forgejo

**Goal:** Forgejo has an `arosenfeld/nixos` repo with full history.

**Tasks:**

1. In Forgejo web UI: create empty repo `arosenfeld/nixos`. Default branch `master`.
2. From laptop:
   ```bash
   git remote rename origin gh-archive
   git remote add origin git@storage.bat-boa.ts.net:2222:arosenfeld/nixos.git
   git push -u origin master --tags
   ```
3. Verify on Forgejo web that history matches GitHub (latest commit SHA on master).

**Success criteria:** Forgejo repo HEAD == laptop master == GitHub master.

**Estimated effort:** 15 minutes

---

#### Phase 4: Stand up runners

**Goal:** Forgejo Actions has two healthy runners; CI is ready to run but no workflows triggered yet.

**Tasks:**

1. In Forgejo: Site Admin → Actions → Runners → "New registration token". Copy the token.
2. `sops --decrypt` then re-encrypt `secrets/sops/basestar.yaml` with `forgejo-runner-token: <token>`.
3. Modify `hosts/basestar/services/development.nix`:
   ```nix
   services.gitea-actions-runner = {
     package = pkgs.forgejo-runner;
     instances.basestar = {
       enable = true;  # was false
       name = "basestar-aarch64";
       url = "https://git.arsfeld.one";  # was forgejo.arsfeld.one
       tokenFile = config.sops.secrets.forgejo-runner-token.path;
       labels = [ "aarch64-linux:host" ];  # cut docker labels — host only
       hostPackages = with pkgs; [
         bash coreutils curl gawk gitMinimal gnused nodejs wget
         nix attic-client jq  # added: nix tooling for the build workflow
       ];
       settings = {
         runner.capacity = 2;  # basestar has 4 cores/24GB; 2x2 cores beats 4x1
       };
     };
   };
   # Cap memory to leave headroom for cross-arch builds:
   systemd.services.gitea-runner-basestar.serviceConfig.MemoryHigh = "16G";
   ```
4. Mirror the same module to a new file `hosts/storage/services/forgejo-runner.nix`:
   ```nix
   { config, pkgs, ... }: {
     sops.secrets.forgejo-runner-token = {};

     services.gitea-actions-runner = {
       package = pkgs.forgejo-runner;
       instances.storage = {
         enable = true;
         name = "storage-x86_64";
         url = "https://git.arsfeld.one";
         tokenFile = config.sops.secrets.forgejo-runner-token.path;
         labels = [ "x86_64-linux:host" ];
         hostPackages = with pkgs; [
           bash coreutils curl gawk gitMinimal gnused nodejs wget
           nix attic-client jq
         ];
         settings = {
           runner.capacity = 3;  # match x86_64 host count
         };
       };
     };
     # Storage co-tenants Plex/*arr — leave headroom:
     systemd.services.gitea-runner-storage.serviceConfig.MemoryHigh = "12G";
   }
   ```
5. Same `forgejo-runner-token` value goes into `secrets/sops/storage.yaml`. (Forgejo registration tokens are reusable across multiple registrations within their TTL window.)
6. Deploy: `just deploy basestar storage`.
7. Verify:
   - Forgejo admin → Actions → Runners shows both runners online with their labels.
   - `journalctl -u gitea-runner-basestar.service` is clean.

**Success criteria:** both runners online and ready in Forgejo admin UI.

**Estimated effort:** 2 hours

---

#### Phase 5: Workflows

**Goal:** Working `build` and `check` workflows triggered on push, validated on a feature branch before cutover.

**Tasks:**

1. Add `ATTIC_TOKEN` as a Forgejo repo secret via the web UI (Settings → Secrets and Variables → Actions → New Secret). Source value from existing GitHub Actions secrets export or sops if previously stored.
2. Create `.forgejo/workflows/build.yaml`:
   ```yaml
   name: build
   on:
     push:
       branches: [master]
     pull_request:
     workflow_dispatch:

   jobs:
     build:
       strategy:
         fail-fast: false
         matrix:
           include:
             - host: storage
               runs-on: x86_64-linux
             - host: raider
               runs-on: x86_64-linux
             - host: blackbird
               runs-on: x86_64-linux
             - host: basestar
               runs-on: aarch64-linux
             - host: r2s
               runs-on: aarch64-linux
             - host: raspi3
               runs-on: aarch64-linux
             - host: octopi
               runs-on: aarch64-linux
       runs-on: ${{ matrix.runs-on }}
       steps:
         - uses: https://data.forgejo.org/actions/checkout@v4
         - name: Build closure
           run: nix build .#nixosConfigurations.${{ matrix.host }}.config.system.build.toplevel -o result-${{ matrix.host }}
         - name: Push to Attic
           env:
             ATTIC_TOKEN: ${{ secrets.ATTIC_TOKEN }}
           run: |
             attic login system https://attic.arsfeld.dev "$ATTIC_TOKEN"
             attic push system ./result-${{ matrix.host }}
   ```
3. Create `.forgejo/workflows/check.yaml`:
   ```yaml
   name: check
   on:
     push:
       branches: [master]
     pull_request:

   jobs:
     flake-check:
       runs-on: x86_64-linux
       steps:
         - uses: https://data.forgejo.org/actions/checkout@v4
         - run: nix flake check --keep-going
     format:
       runs-on: x86_64-linux
       steps:
         - uses: https://data.forgejo.org/actions/checkout@v4
         - run: nix run nixpkgs#alejandra -- --check .
   ```
4. Push these on a **feature branch** to Forgejo: `git checkout -b ci/forgejo-actions && git push origin ci/forgejo-actions`.
5. Watch all 7 build matrix jobs + 2 check jobs run; fix anything that diverges from GHA expectations (fully-qualified `data.forgejo.org/actions/*` URLs, environment variable quirks).
6. Merge feature branch to `master`.

**Success criteria:**
- All 7 host closures build green within 90 minutes
- All 7 closures present in Attic (`attic --help cache info system` lists them)
- `flake-check` and `format` jobs green
- No QEMU usage observed in runner logs (confirming native execution)

**Estimated effort:** 1 day (most of it debugging Forgejo Actions ↔ GHA differences)

---

#### Phase 6: Push-mirror to GitHub + cutover

**Goal:** Forgejo is the single source of truth. Every push mirrors to GitHub. `.github/workflows/` is gone. GitHub repo is archived.

**Tasks:**

1. Generate a GitHub fine-grained PAT scoped to `arsfeld/nixos`, permissions: `Contents: Read and write` + `Workflows: Read and write` (so the cutover commit deleting `.github/workflows/` actually propagates), expiry 1 year.
2. `sops` it into `secrets/sops/storage.yaml` as `forgejo-github-mirror-pat`.
3. **Configure push mirror manually** (one-time, in the Forgejo web UI):
   - Navigate to repo Settings → Mirror Settings → Add Push Mirror
   - Remote URL: `https://github.com/arsfeld/nixos.git`
   - Username: `arsfeld`
   - Password: the GitHub PAT
   - Interval: `8h0m0s`
   - Tick "Sync on commit"

   Or via API (single curl from the laptop, no systemd unit needed):
   ```bash
   PAT_SOPS=$(ssh storage 'sudo cat /run/secrets/forgejo-github-mirror-pat')
   FORGEJO_TOKEN=$(forgejo-admin-pat-from-your-password-manager)
   curl -fsS -H "Authorization: token $FORGEJO_TOKEN" \
     -H "Content-Type: application/json" \
     -X POST https://git.arsfeld.one/api/v1/repos/arosenfeld/nixos/push_mirrors \
     -d "{\"remote_address\":\"https://github.com/arsfeld/nixos.git\",
          \"remote_username\":\"arsfeld\",
          \"remote_password\":\"$PAT_SOPS\",
          \"interval\":\"8h0m0s\",
          \"sync_on_commit\":true}"
   ```
   *PAT for the Forgejo-side API call: generate one once via web UI (Settings → Applications → Generate New Token) and stash it in your password manager.*
4. Deploy: `just deploy storage` (only needed if you also want the `forgejo-github-mirror-pat` sops secret available; otherwise the manual API call uses the value directly from sops on storage).
5. Verify mirror:
   - In Forgejo: repo Settings → Mirror Settings shows `https://github.com/arsfeld/nixos.git` with sync_on_commit
   - Push a trivial commit to Forgejo master → GitHub HEAD updates within 60s
6. **Cutover commit** (single commit on Forgejo master):
   - Delete `.github/workflows/`
   - Update `CLAUDE.md` CI/CD section to reflect Forgejo Actions
   - Update CI badge / README links if any
7. Push cutover commit. Verify mirror propagates the deletion to GitHub. Confirm GHA stops triggering (no more new Action runs on GitHub).
8. **GitHub repo stays public and active** — no archive step. The mirror is force-push, so any direct GitHub push (yours or someone else's) gets clobbered on the next Forgejo push. That's the intended behavior of a one-way mirror; public discoverability is preserved.
9. On the laptop:
   ```bash
   git remote rename gh-archive github-archive  # cosmetic — Forgejo is `origin` per Phase 3
   git fetch --all
   ```

**Success criteria (from SpecFlow acceptance checklist):**
- [ ] `git clone https://git.arsfeld.one/arosenfeld/nixos.git /tmp/x` works from a fresh laptop with only a Forgejo PAT
- [ ] Push to Forgejo `master` → all 7 host builds green within 90 min → all 7 closures present in Attic
- [ ] Push to Forgejo `master` → GitHub `arsfeld/nixos` HEAD matches Forgejo HEAD within 60s
- [ ] Web SSO via Authelia works for the admin user; `systemctl stop authelia` → git over SSH still works
- [ ] Stop forgejo, restore from a restic snapshot, restart → repo accessible at last commit
- [ ] After deleting `.github/workflows/` and pushing, no new GHA runs are triggered on GitHub

**Estimated effort:** 1 day (mostly verification + paranoid checks before archiving GitHub)

---

#### Phase 7 (deferred): Weekly flake-input bumper

Out of initial scope. Once the Forgejo Actions workflow is stable, port `update.yml` to a Forgejo workflow that opens a PR (not a direct master commit) using a dedicated `flake-bot` Forgejo user with a separate PAT. PR-based workflow is the upgrade vs today's "bot commits to master" pattern.

### forgejo.nix Sketch

Reference structure (paths relative to repo root):

```nix
# hosts/storage/services/forgejo.nix
{ config, pkgs, lib, ... }:
let
  vars = config.media.config;
in {
  users.users.forgejo = {
    isSystemUser = true;
    group = "forgejo";
    uid = 991;  # stable; pick an unused UID >= 990
    home = "/var/lib/forgejo";
    createHome = true;
  };
  users.groups.forgejo.gid = 991;

  sops.secrets.forgejo-oidc-secret = { mode = "0400"; owner = "forgejo"; };
  sops.secrets.forgejo-jwt-secret  = { mode = "0400"; owner = "forgejo"; };
  sops.secrets.forgejo-github-mirror-pat = { mode = "0400"; owner = "forgejo"; };

  services.forgejo = {
    enable = true;
    package = pkgs.forgejo-lts;
    stateDir = "/var/lib/forgejo";
    lfs.enable = false;
    secrets.oauth2.JWT_SECRET = config.sops.secrets.forgejo-jwt-secret.path;
    settings = {
      DEFAULT.APP_NAME = "Forgejo";
      server = {
        DOMAIN = "git.${vars.domain}";
        ROOT_URL = "https://git.${vars.domain}/";
        HTTP_PORT = 3001;
        START_SSH_SERVER = true;
        SSH_PORT = 2222;
        SSH_LISTEN_HOST = "100.x.y.z";  # storage's tailscale IP — pin via config or interface lookup
        DISABLE_SSH = false;
      };
      service = {
        DISABLE_REGISTRATION = true;
        ALLOW_ONLY_EXTERNAL_REGISTRATION = true;
        SHOW_REGISTRATION_BUTTON = false;
      };
      openid = {
        ENABLE_OPENID_SIGNIN = false;  # disable legacy OpenID 2.0
        ENABLE_OPENID_SIGNUP = false;
      };
      oauth2_client = {
        ENABLE_AUTO_REGISTRATION = true;
        ACCOUNT_LINKING = "auto";
        UPDATE_AVATAR = true;
        USERNAME = "nickname";
      };
      actions.ENABLED = "true";
      repository.DEFAULT_BRANCH = "master";
      mirror.DEFAULT_PUSH_MIRROR_INTERVAL = "8h0m0s";
    };
  };

  # No bootstrap systemd units — admin user, OAuth source, and push mirror
  # are configured manually one-time after first deploy. See Phase 1 task 11,
  # Phase 2 step 4, and Phase 6 step 3.

  # Gateway entry: rename forgejo → git, drop funnel, bypassAuth
  # bypassAuth is required: Forgejo handles auth via Authelia OIDC + local
  # form-auth fallback. Without it, Caddy double-auths and OIDC callbacks 401.
  media.gateway.services.git = {
    port = 3001;
    exposeViaTailscale = true;
    settings.funnel = false;
    settings.bypassAuth = true;
  };
}
```

## Alternative Approaches Considered

Captured in the brainstorm; carried forward here as the "rejected" record:

| Alternative | Why rejected |
|---|---|
| Full migration off GitHub | Loses public discoverability and DR fallback |
| GitLab CE | Too heavy for solo personal infra |
| Sourcehut | Mailing-list workflow doesn't match how we work |
| Bare repo on storage | No CI, no web UI, no PR review surface |
| Hydra | Heavyweight; very different ergonomics from GHA |
| Hercules CI | Not self-hosted-first |
| Self-hosted GHA runners on storage | Still depends on GitHub for orchestration |
| Auto-deploy from CI | Circular dependency risk; deploy stays on the laptop |
| Forgejo Actions runner in Docker mode | Loses host `/nix` store access; meaningful only for multi-tenant repos |
| LLDAP `forgejo-admins` group with `--admin-group` mapping | Overkill for one user; LLDAP groups aren't declarative in this repo |
| Hourly backups | Live GitHub mirror already provides sub-minute RPO |
| Forgejo `dump` for backups | Has known long-standing import bugs in 2025/2026 |
| Cloudflared TCP tunnel for SSH | Requires `cloudflared access ssh` on every client; breaks fresh-laptop clone |
| `/var/data/forgejo` state dir | Diverges from module default; buys nothing |
| Tailscale Funnel for Forgejo | Wider attack surface than cloudflared, no WAF |

## System-Wide Impact

### Interaction Graph

When a `git push origin master` lands on Forgejo:

1. **Forgejo `repo-server`** writes the ref to disk → triggers post-receive hooks
2. **Forgejo Actions scheduler** queues matrix jobs (build × 7 hosts, check × 2)
3. **Push mirror dispatcher** queues a mirror push to GitHub (sync_on_commit)
4. **storage runner** picks up `runs-on: x86_64-linux` jobs (3 hosts), executes via host shell with `hostPackages` in PATH; runs `nix build`; uses storage's existing remote-builder config to invoke basestar for any cross-arch Nix dependencies inside the build (rare for these closures)
5. **basestar runner** picks up `runs-on: aarch64-linux` jobs (4 hosts), executes natively
6. Each successful build → `attic push` → existing Attic at attic.arsfeld.dev (Traefik on can-1) accepts the upload
7. Push mirror runs `git push --mirror` to GitHub with the configured PAT → GitHub repo HEAD updates
8. **Authelia stays uninvolved** unless someone is browsing the web UI

### Error & Failure Propagation

| Failure | Where surfaces | Recovery |
|---|---|---|
| Runner offline | Forgejo Actions → "no runners with label X" → job fails fast | systemd restart (`systemctl restart gitea-runner-basestar`) |
| `nix build` failure | Single matrix job fails; others continue (`fail-fast: false`) | Fix the offending host config |
| `attic push` failure | Build job fails after build success → cache misses next deploy | Re-run job; verify `ATTIC_TOKEN` |
| Push mirror failure | Forgejo logs only — no notification today | Add Gatus monitor on GitHub HEAD lag (Phase 7+) |
| Forgejo OAuth source mis-config | Sign-in fails silently (Authelia thinks all is well) | Bootstrap admin local password (filesystem) is the break-glass |
| Authelia outage | Web SSO 502s | Git over SSH still works; bootstrap admin local password works for web break-glass |
| sops secret missing on first activation | Forgejo systemd unit fails to start | Two-phase deploy: skip dependent secrets until Phase 4 |
| GitHub PAT expires | Mirror starts failing silently | Calendar reminder + Gatus monitor (Phase 7+) |

### State Lifecycle Risks

| Step | Persists | Partial-failure risk | Mitigation |
|---|---|---|---|
| Bootstrap admin script | `.bootstrap-admin-password`, `.bootstrap-admin-token` | If `forgejo admin user create` succeeds but `generate-access-token` fails, marker file isn't written → script re-runs and re-creates user (idempotent `\|\| true` covers it) | Marker file + idempotent commands |
| OAuth source script | Forgejo DB row | If create succeeds but marker file write fails → script re-runs → second OAuth source created. **Risk.** | Add explicit `forgejo admin auth list \| grep -q authelia` check before insert |
| Push mirror oneshot | DB row + marker file | Same as above — uses marker file | If race occurs, manually `DELETE` via API and re-run |
| `attic push` mid-build | Attic upload state | Partial closure uploads are deduplicated server-side; safe to re-run | None needed |
| Mirror push | GitHub repo state | force-push is the design; intentional overwrite | If GitHub gets ahead (someone pushes there), overwrite is on purpose |

### API Surface Parity

The repo currently has these Git-touching surfaces:

| Surface | Today | After |
|---|---|---|
| `git remote get-url origin` (laptop) | `git@github.com:arsfeld/nixos.git` | `git@storage.bat-boa.ts.net:2222:arosenfeld/nixos.git` |
| GitHub Actions workflows | `.github/workflows/*` | Deleted; `.forgejo/workflows/*` |
| CI cache | Attic via GHA secret | Attic via Forgejo secret |
| nixos-rebuild flake URL | `github:arsfeld/nixos` (in some hosts' `programs.nix-ld` etc.) | Audit: grep for `github:arsfeld` and consider switching to `git+https://git.arsfeld.one/arosenfeld/nixos` or a flake-registry override |
| flake input references in any *consumer* of this repo | n/a | n/a (this is a leaf flake) |
| Documentation links | README.md (if any), CLAUDE.md | Update to Forgejo URLs |

### Integration Test Scenarios

Cross-layer tests unit tests with mocks would not catch:

1. **First-deploy bootstrap**: Wipe `/var/lib/forgejo`, deploy storage, verify admin password file appears, can log in, OAuth source registers, can access admin UI.
2. **Phase 4 runner registration**: Generate registration token via Forgejo CLI, sops it, deploy basestar, verify runner shows online in Forgejo within 30s.
3. **Authelia outage during runner job**: Stop Authelia mid-build, verify the runner completes its job (it doesn't talk to Authelia — only the web UI does).
4. **Push-mirror under conflict**: Manually push directly to GitHub from another clone, then push to Forgejo, verify Forgejo's force-push wins on the next mirror sync.
5. **Restore drill**: Stop forgejo, `rustic restore` last snapshot to scratch, verify SQLite integrity (`sqlite3 forgejo.db "PRAGMA integrity_check;"`), restart pointing to scratch dir, repo accessible at last commit.
6. **PAT rotation**: Rotate GitHub PAT → update sops → manually re-trigger `forgejo-bootstrap-mirror` (after deleting marker + DELETE old mirror via API), verify next push mirrors successfully.

## Acceptance Criteria

### Functional Requirements

- [ ] Forgejo healthy at `https://git.arsfeld.one/api/healthz`
- [ ] Authelia OIDC sign-in to Forgejo works; user is admin
- [ ] Bootstrap admin password file readable on storage filesystem (break-glass)
- [ ] Git push to `https://git.arsfeld.one/arosenfeld/nixos.git` works with a Forgejo PAT (HTTPS)
- [ ] Git push to `git@storage.bat-boa.ts.net:2222:arosenfeld/nixos.git` works with SSH key (Tailscale only)
- [ ] All 7 host closures build green via Forgejo Actions on push to master
- [ ] All 7 closures land in Attic (`attic cache info system` shows them)
- [ ] `nix flake check` and `alejandra --check` jobs run on push and PR
- [ ] Push to Forgejo master → GitHub HEAD matches within 60s
- [ ] `.github/workflows/` directory does not exist on master after cutover (mirror propagated the deletion to GitHub; no new GHA runs trigger)

### Non-Functional Requirements

- [ ] CI walltime: **≤ 50 min P50, ≤ 75 min P95** for full 7-host matrix, measured from run #4 onward (cold-cache pre-warm caveat for runs 1–3)
- [ ] No QEMU emulation observed in any runner log (native execution confirmed)
- [ ] Forgejo state dir (`/var/lib/forgejo`) included in daily rustic backup, with SQLite `.backup` pre-hook
- [ ] Sign-in flow stays under 5 second perceived latency on tailscale

### Quality Gates

- [ ] `nix flake check` passes locally before merging the cutover commit
- [ ] All NixOS modules pass `alejandra --check`
- [ ] No new `Aborted!` errors in the last 100 lines of any service journal post-deploy
- [ ] `nixos-rebuild test` succeeds before `nixos-rebuild switch` for storage and basestar
- [ ] `just build storage` and `just build basestar` succeed locally on the laptop

## Success Metrics

- **Time to first green build on Forgejo:** target ≤ 1 day from Phase 4 start.
- **Mirror lag:** GitHub HEAD ≤ 60s behind Forgejo HEAD on `master`. **Gatus check enforces this** (alert at >5 min lag — added in Phase 6, not deferred).
- **CI walltime parity:** ≤ 50 min P50, materially faster than today's QEMU-emulated GHA (~70-80 min). Native execution should be a clear win, not parity.
- **Outage independence:** at least one validated incident where storage is reachable but GitHub or Authelia is unreachable, and the team can still ship a change (track once).

## Dependencies & Prerequisites

- nixpkgs has `pkgs.forgejo-lts` (verified — currently 14.0.4)
- `services.gitea-actions-runner` works with `pkgs.forgejo-runner` (verified)
- Authelia config supports declarative OIDC clients via the `authelia-secrets` sops blob (verified — pattern exists, no clients yet)
- Existing storage cloudflared wildcard tunnel for `*.arsfeld.one` (no changes needed)
- Existing Attic cache + `ATTIC_TOKEN` (just need to copy token into Forgejo secrets)
- Existing rustic backup infra (`modules/constellation/backrest.nix`)
- Existing remote-builder config (`nix-builders.conf`) — runners benefit from this for cross-arch Nix dependencies, no changes needed

## Risk Analysis & Mitigation

| Risk | Severity | Mitigation |
|---|---|---|
| Hard cutover hides a Forgejo Actions ↔ GHA incompatibility (Attic auth, action proxy quirk) | High | Phase 5 trial on feature branch before deletion; keep `github-archive` remote on the laptop for emergency push-back |
| Storage as source of truth = single point of failure | High | Live (un-archived) GitHub mirror provides sub-minute RPO; daily restic + weekly restore drill; off-site copy at Hetzner via existing backrest plan |
| Authelia outage blocks Forgejo web | Medium | Manually-set admin password (saved in password manager) usable as form-auth break-glass; git over SSH never depends on Authelia |
| Accidental `git push` to GitHub (un-archived) | Low | Mirror force-pushes from Forgejo on next sync — direct push gets clobbered cleanly. Acceptable; this is the design |
| Push mirror PAT expires silently | Medium | 1-year expiry + calendar reminder; Phase 7 follow-up adds a Gatus monitor on `github.com/arsfeld/nixos` HEAD lag |
| Runner registration token leak | Medium | Tokens are short-lived (TTL minutes); rotation = new registration token + wipe `.runner` + restart (documented below) |
| First-activation race between sops `chown forgejo` and Forgejo user creation | Medium | Pin `users.users.forgejo` with stable UID/GID before service activation |
| OAuth source registered twice from non-idempotent script | Low | Marker file + explicit `auth list \| grep authelia` precondition |
| basestar building basestar (self-hosted on the host being built) | Low | Acceptable; if basestar's closure breaks, fall back to QEMU on storage's runner via remote-builder; still better than today's GHA QEMU |
| Forgejo v15 LTS upgrade pain | Low | Pin `pkgs.forgejo-lts`; let nixpkgs catch up to 15.x in May before bumping; intermediate migration via release notes |

## Resource Requirements

- **Time:** ~3 working days end-to-end (Phase 1+2 day 1, Phase 3+4 day 2, Phase 5+6 day 3 + verification overnight)
- **People:** solo
- **Hardware:** existing storage + basestar; no new infra
- **External services:** GitHub fine-grained PAT (1y), no other paid changes

## Future Considerations

- **Phase 7 — Weekly flake bumper as Forgejo Actions workflow** with a dedicated bot user opening PRs (not master commits)
- **Phase 8 — Gatus monitor for mirror-lag and PAT-expiry**
- **Phase 9 — Migrate to a NixOS-runner-image pattern** if/when contribution surface grows beyond solo (security: host-mode is unsafe for untrusted PRs)
- **Phase 10 — Forgejo `nixos`-channel-style attic cache** (optional; existing Attic is already serving this purpose)
- **Phase 11 — flake-registry override** so `nix run github:arsfeld/...` calls in scripts elsewhere transparently resolve to the Forgejo URL

## Token / Secret Rotation Procedures

### `forgejo-oidc-secret` (Authelia ↔ Forgejo OIDC)

Rotate when: leaked, or every 12 months.
1. Generate new cleartext: `openssl rand -hex 32`
2. Hash via `authelia crypto hash generate pbkdf2 --variant sha512 --iterations 310000`
3. Update `forgejo-oidc-secret` and the `authelia-secrets.identity_providers.oidc.clients[?id==forgejo].client_secret` in `secrets/sops/storage.yaml`
4. `just deploy storage` → both Authelia and Forgejo restart in a coordinated way
5. Existing OAuth source in Forgejo doesn't need re-registration; the secret is read from credentials at startup

### `forgejo-runner-token` (registration only)

Tokens are **one-shot** (consumed on registration). To re-register a runner:
1. Forgejo admin UI → Actions → Runners → delete existing runner row
2. Generate new registration token from same UI
3. sops the new value into `secrets/sops/<host>.yaml`
4. `systemctl stop gitea-runner-<name>; rm /var/lib/gitea-runner-<name>/.runner; systemctl start gitea-runner-<name>`
5. New `.runner` file is written with the new credential

### `forgejo-github-mirror-pat` (GitHub PAT)

1. GitHub → Settings → Developer settings → Personal access tokens → fine-grained → regenerate or generate-new
2. Permissions: `Contents: Read and write` + `Workflows: Read and write`, scope: `arsfeld/nixos` only, expiry 1y
3. sops new value into `forgejo-github-mirror-pat`
4. **Push mirror config does NOT auto-pick up the new PAT.** The Forgejo API doesn't allow patching `remote_password`. Procedure (manual, from laptop):
   ```bash
   FORGEJO_ADMIN_PAT=$(<password manager>)
   # List + find the mirror id:
   curl -fsS -H "Authorization: token $FORGEJO_ADMIN_PAT" \
     https://git.arsfeld.one/api/v1/repos/arosenfeld/nixos/push_mirrors
   # Delete it:
   curl -fsS -X DELETE -H "Authorization: token $FORGEJO_ADMIN_PAT" \
     https://git.arsfeld.one/api/v1/repos/arosenfeld/nixos/push_mirrors/{id}
   # Re-add via web UI (Repo → Settings → Mirror Settings) or POST API
   # call (see Phase 6 step 3) with the new PAT.
   ```

### `forgejo-jwt-secret` (Forgejo internal OAuth2 JWT signing key)

Rotate only on compromise. Rotation invalidates all existing OAuth tokens (re-login required).
1. Generate: `openssl rand -base64 32`
2. sops it
3. `systemctl restart forgejo`

### `ATTIC_TOKEN` (in Forgejo Actions secrets)

Rotated via the existing Attic admin process; update via Forgejo web UI under repo Settings → Secrets.

## Disaster Recovery Runbook

### Scenario: storage is unavailable, but data is intact (e.g., kernel panic)

1. Reboot storage; if Forgejo doesn't start, `journalctl -u forgejo` for cause
2. RTO target: < 15 min (boot + service start)

### Scenario: storage data loss (rustic restore needed)

1. Reprovision storage hardware (or restore from a system snapshot)
2. `colmena apply --on storage` to get back to base config (Forgejo will start with empty state dir → bootstrap script runs again)
3. **Stop Forgejo:** `systemctl stop forgejo`
4. **Restore Forgejo state from rustic:**
   ```bash
   rustic restore --target /var/lib/forgejo latest:/var/lib/forgejo
   chown -R forgejo:forgejo /var/lib/forgejo
   ```
5. **SQLite integrity check:** `sudo -u forgejo sqlite3 /var/lib/forgejo/data/forgejo.db "PRAGMA integrity_check;"`
6. **Remove bootstrap markers** so they don't re-run (they're idempotent but the OAuth-source one might create duplicates if checks are skipped):
   ```bash
   rm -f /var/lib/forgejo/.bootstrap-*-done /var/lib/forgejo/.mirror-bootstrap-done
   ```
7. `systemctl start forgejo`
8. Verify: web UI loads, `arosenfeld/nixos` repo accessible, latest commit matches expected SHA
9. RTO target: < 1h (depends on rustic restore time)

### Scenario: nuclear option — both storage data AND backups gone

1. `git clone https://github.com/arsfeld/nixos.git` from the still-archived (read-only) GitHub mirror
2. Reprovision storage from scratch via colmena; Forgejo bootstraps a fresh empty repo
3. From the GitHub clone:
   ```bash
   git remote add origin git@storage.bat-boa.ts.net:2222:arosenfeld/nixos.git
   git push -u origin master --tags
   ```
4. Re-trigger Phase 6 push-mirror bootstrap (after un-archiving GitHub) so writes resume mirroring
5. RTO target: < 4h (no SLA — this is "house fire" tier)

### Scenario: Authelia broken, can't sign in via web

1. Sign in to Forgejo web with `arosenfeld` + the admin password from your password manager (form-based auth still works alongside OIDC)
2. If you've forgotten the password: `ssh storage 'sudo -u forgejo GITEA_WORK_DIR=/var/lib/forgejo forgejo admin user change-password --username arosenfeld --password <new>'`
3. Fix Authelia separately

### Scenario: GitHub PAT lost mid-rotation (mirror down)

Push-mirror just stops working — Forgejo retains source of truth. Follow the PAT rotation procedure above; mirror resumes on next push.

## Edge Cases Captured

(From SpecFlow analysis — full list with severities in the analysis output; the BLOCKERs are addressed in the phases above. The remaining items:)

- **LFS:** disabled explicitly via `services.forgejo.lfs.enable = false;`
- **Submodules:** none today; if added, push them first before relying on mirror
- **Filesystem permissions race:** addressed by pinned `users.users.forgejo` UID/GID before service activation
- **Runner walltime:** addressed by capacity bumps (basestar=4, storage=3) matching matrix counts
- **`develop.nix` mixing Forgejo + code-server:** split — `forgejo.nix` is its own file
- **`WHITELISTED_URIS` config bug:** removed (it's the wrong setting; applies to legacy OpenID 2.0)
- **`funnel = true` on Forgejo:** changed to `false` — cloudflared only

## Documentation Plan

- Update `CLAUDE.md` CI/CD section to describe Forgejo Actions instead of GitHub Actions
- Update `CLAUDE.md` "Available Hosts" to mention `git.arsfeld.one`
- Add a HOSTING.md (or section in CLAUDE.md) documenting the bootstrap-admin password retrieval and break-glass procedure
- Cross-reference this plan from `docs/architecture/backup.md` since Forgejo is now a primary backup target

## Sources & References

### Origin

- **Brainstorm document:** [docs/brainstorms/2026-04-27-self-host-forgejo-brainstorm.md](../brainstorms/2026-04-27-self-host-forgejo-brainstorm.md)
  - Decisions carried forward: primary on storage with GitHub mirror; Forgejo over Gitea/GitLab; Forgejo Actions runners on host system; Authelia OIDC; hard cutover; SQLite over Postgres; CI scope = build + flake check + format check (auto-deploy and weekly bumper deferred)

### Internal References

- `hosts/storage/services/develop.nix:33-65` — existing partial `services.forgejo` config (will be moved out and rewritten)
- `hosts/basestar/services/development.nix:19-36` — disabled runner instance to enable
- `modules/media/gateway.nix:38-106` — `media.gateway.services` registry (adds `git` entry)
- `modules/media/__utils.nix:87-173` — Caddy vhost generation; `bypassAuth` setting at `:128-138`
- `hosts/storage/services/cloudflared.nix:1-21` — wildcard ingress for `*.arsfeld.one`
- `hosts/storage/services/auth.nix:14-119` — Authelia + LLDAP; OIDC clients live in `authelia-secrets` sops blob (per repo-research, no declarative client list in nix today)
- `hosts/storage/backup/backrest-client.nix:117-181` — backrest plans on storage
- `secrets/sops/storage.yaml:17` — `forgejo-oidc-secret` placeholder (populate in Phase 2)
- `secrets/sops/basestar.yaml:10` — `forgejo-runner-token: ""` placeholder (populate in Phase 4)
- `.github/workflows/build.yml` — current GHA build that we replicate then delete
- `.github/workflows/format.yml`, `update.yml` — same
- `nix-builders.conf` — basestar as aarch64 remote builder; runners inherit this for cross-arch Nix deps
- `flake-modules/colmena.nix:41-62` — cross-compile fallback for aarch64 hosts (still relevant if a runner is down)
- Memory: `feedback_sops_automated.md` — sops fully automated, never interactive
- Memory: `project_attic_nvidia_issue.md` — Attic at attic.arsfeld.dev = Traefik in k3s on can-1
- Memory: `feedback_no_find_nix_store.md` — never find /nix/store

### External References

- [Forgejo Actions reference](https://forgejo.org/docs/latest/user/actions/)
- [Forgejo Actions ↔ GitHub Actions compatibility](https://forgejo.org/docs/latest/user/actions/github-actions/)
- [Forgejo repository mirroring](https://forgejo.org/docs/latest/user/repo-mirror/)
- [Forgejo admin command-line](https://forgejo.org/docs/latest/admin/command-line/) — `forgejo admin auth add-oauth`
- [Forgejo v15.0 release announcement (2026-04-16)](https://forgejo.org/2026-04-release-v15-0/)
- [Forgejo on endoflife.date](https://endoflife.date/forgejo)
- [Authelia OIDC provider config](https://www.authelia.com/configuration/identity-providers/openid-connect/provider/)
- [Authelia OIDC client config](https://www.authelia.com/configuration/identity-providers/openid-connect/clients/)
- [Authelia ↔ Forgejo integration guide](https://www.authelia.com/integration/openid-connect/clients/forgejo/)
- [NixOS `services.forgejo` source](https://raw.githubusercontent.com/NixOS/nixpkgs/nixos-unstable/nixos/modules/services/misc/forgejo.nix)
- [NixOS `services.gitea-actions-runner` source](https://raw.githubusercontent.com/NixOS/nixpkgs/nixos-unstable/nixos/modules/services/continuous-integration/gitea-actions-runner.nix)
- [NixOS `services.authelia` source](https://raw.githubusercontent.com/NixOS/nixpkgs/nixos-unstable/nixos/modules/services/security/authelia.nix)
- [Attic CLI reference](https://docs.attic.rs/reference/attic-cli.html)
- [Forgejo backup/restore guidance — Arjen Wiersma](https://www.arjenwiersma.nl/restoring-a-forgejo-backup) (note: `forgejo dump` has known import bugs; filesystem snapshot preferred)
- [NixOS runners on Forgejo Actions (community write-up)](https://simonshine.dk/articles/forgejo-actions-nixos-runners/) — host vs container exec discussion
- [selfhostblocks/modules/services/forgejo.nix](https://github.com/ibizaman/selfhostblocks/blob/main/modules/services/forgejo.nix) — reference for declarative admin + OAuth source bootstrap pattern (idempotent CLI checks, no marker files)
- [oddlama/nix-config — forgejo with Kanidm OAuth](https://github.com/oddlama/nix-config/blob/main/hosts/ward/guests/forgejo.nix) — declarative `oauth2_client` settings example
- [systemd #32583 — `LoadCredential` + `ReadWritePaths` interaction bug](https://github.com/systemd/systemd/issues/32583) — explains why bootstrap should live in a separate unit
- [Red Hat — `Type=oneshot` service](https://www.redhat.com/en/blog/systemd-oneshot-service)
- [NixOS Asia — `writeShellApplication`](https://nixos.asia/en/writeShellApplication) — preferred over `writeShellScript` for bootstrap shell scripts (sets PATH, shellcheck at build time)

---

## Deep Review Findings

Comprehensive punch list from the deepen pass. Findings marked **APPLIED** are reflected in the [Enhancement Summary](#enhancement-summary-post-deepen-pass) at the top of this plan or in the inline edits to the plan body. Findings marked **PENDING** must be applied during implementation; each lists the concrete file/line to touch.

### Bootstrap & Idempotency

| # | Sev | Finding | Status |
|---|-----|---------|--------|
| B1-B6 | — | All declarative-bootstrap considerations (separate oneshot unit, marker-file idempotency, password file overwrite race, `preStart` vs `ExecStartPost`, `writeShellApplication`, `sd_notify` readiness). | **OBSOLETE** — superseded by user decision: bootstrap is now manual one-time steps, not systemd-driven. See Enhancement Summary §2. |

### Backup & Data Integrity

| # | Sev | Finding | Status |
|---|-----|---------|--------|
| D1 | — | Backrest+restic schema correction (was rustic / `hooks.before`). | **APPLIED** as docs note in Enhancement Summary §1 — hooks not used at all per user. |
| D2 | HIGH | Verify `/var/lib` is in **all three** Backrest plans (`local`, `hetzner`, `pegasus`). Off-site plans currently target only `/home` and `/mnt/storage`; add `/var/lib` to their `paths` if not already. | **PENDING** — Phase 1 task 12 |
| D3 | — | Snapshot atomicity via `systemctl stop forgejo`. | **OBSOLETE** — user overruled as overcooked. Hot snapshot is fine; SQLite recovers, GitHub mirror covers refs at sub-minute RPO. |
| D4 | HIGH | "GitHub mirror = sub-minute RPO" applies to **git refs only** — NOT issues, PRs, OAuth source, runner registrations, Actions secrets, run history, webhooks, settings, OIDC links. Restate as "sub-minute RPO for refs; 24h RPO for Forgejo metadata." | **APPLIED** in narrative; explicitly note in plan acceptance criteria during implementation |
| D5 | MEDIUM | DR runbook: add `forgejo doctor check --all` post-restore (catches application-layer consistency, not just SQLite B-tree integrity). | **PENDING** — DR runbook update |
| D6 | — | WAL/SHM split risk during snapshot. | **OBSOLETE** — accepted as inherent to hot-snapshot strategy; rely on SQLite recovery + GitHub mirror. |
| D7 | LOW | RTO numbers: warm-restart < 15 min, restic-restore < 4h, cold rebuild < 24h. | **PENDING** — DR section wording |

### Secrets & Tokens

| # | Sev | Finding | Status |
|---|-----|---------|--------|
| S1 | CRITICAL | Bootstrap admin password is unrotated, captured into every restic snapshot forever. Even after rotating live, past backups retain working break-glass. Mitigations: (a) rotate after first successful Authelia login + re-seal; (b) exclude `.bootstrap-admin-password` from backup paths; (c) enable TOTP on the local admin account so password alone is insufficient. | **PENDING** — add to Phase 2 (post-OIDC verification) |
| S2 | HIGH | Push-mirror PAT scope: `Workflows: write` needed only for cutover commit deleting `.github/workflows/`. After cutover lands, regenerate as `Contents: write` only. | **APPLIED** (Enhancement Summary §9 — new Phase 6.1) |
| S3 | HIGH | Action `uses:` pinned to tags (`@v4`) is vulnerable to tag-move attacks. Pin to commit SHAs everywhere. | **APPLIED** (Enhancement Summary §10) |
| S4 | HIGH | `ATTIC_TOKEN` in env at job time = compromised flake input can exfiltrate. Mitigations: scope token to push-only (verify Attic supports), wrap `attic push` to scrub env from children, schedule rotation (12 months) and after non-nixpkgs flake bumps. | **PENDING** — Phase 4 / Phase 5 workflow hardening |
| S5 | MEDIUM | Authelia OIDC: `userinfo_signed_response_alg: none` is vulnerable to TLS-stripping mid-tunnel. Set to `RS256` if Forgejo verifies. `consent_mode: pre-configured` with 1 month is permissive for solo — consider 2 weeks. Add `groups` scope now even if unused (avoids forced re-link later). | **PENDING** — Phase 2 OIDC client config |
| S6 | MEDIUM | Same `forgejo-runner-token` value sopsed across both hosts is dead weight after registration (registration tokens are short-TTL one-shot; long-lived runner secret lives in `.runner` file). Document that the secret in sops is stale post-registration; rotation = new registration token + wipe `.runner`. | **PENDING** — sops file comment + rotation runbook |
| S7 | MEDIUM | Restic password is now a Tier-0 secret guarding OAuth JWT signing key + `ATTIC_TOKEN`. Verify per-repo unique passwords (currently `restic-password` is shared across `local`, `hetzner`, `pegasus` plans per `backrest-client.nix:122-133`). Annual rotation cadence. | **PENDING** — sops audit |

### Performance & Capacity

| # | Sev | Finding | Status |
|---|-----|---------|--------|
| P1 | HIGH | basestar `runner.capacity = 4` is wrong (4 cores / 24 GB → memory + CPU saturation). Drop to 2; add `MemoryHigh = "16G"` on the runner slice. | **APPLIED** (inline Phase 4 edit) |
| P2 | HIGH | Walltime target ≤ 90 min is a regression from today's ~70-80 min QEMU GHA. Native should be 35-45 min total. Tighten NFR to ≤ 50 min P50, ≤ 75 min P95, measured from run #4 onward. | **APPLIED** (inline Acceptance Criteria edit) |
| P3 | MEDIUM | storage runner `capacity = 3` co-tenants Plex/*arr — add `MemoryHigh = "12G"` to leave headroom. | **APPLIED** (inline Phase 4 edit) |
| P4 | MEDIUM | I/O contention on storage NVMe: Forgejo SQLite + `/nix/store` writes + Plex transcode scratch. Add `IOWeight=80` on Plex, `IOWeight=50` on forgejo, default for runner. Route Forgejo logs to journald (`settings.log.MODE = "console"`). | **PENDING** — Phase 1 forgejo.nix |
| P5 | MEDIUM | Forgejo Actions retention unbounded by default. Add `actions.LOG_RETENTION = "30d"`, `actions.ARTIFACT_RETENTION_DAYS = 14`, `cron.cleanup_actions.ENABLED = "true"`. Monthly `VACUUM` cron. | **APPLIED** (Enhancement Summary §11) — concrete settings added below |
| P6 | MEDIUM | `attic push` parallelism: 7 closures × parallel pushes saturate uplink. Use `attic push --jobs 8` per invocation; serialize multiple `attic push` invocations on the same runner via workflow `concurrency:` group. | **PENDING** — Phase 5 workflow YAML |
| P7 | LOW | First 3 runs hit cold-cache; expect 1.3-1.5× walltime. Document so the walltime target measurement starts from run #4. | **APPLIED** (inline Acceptance Criteria edit) |
| P8 | LOW | Runner workdir disk: budget 10 GB on storage, 5 GB on basestar. Add `systemd.tmpfiles.rules = [ "e /var/lib/gitea-runner-<name>/cache - - - 7d" ]`. | **PENDING** — Phase 4 |
| P9 | LOW | Push-mirror queue: explicit `[queue.mirror] LENGTH = 100; BATCH_LENGTH = 1` so bursts don't drop. | **PENDING** — Phase 1 forgejo.nix |

### Architecture & Failure Domains

| # | Sev | Finding | Status |
|---|-----|---------|--------|
| A1 | CRITICAL | Plan claims runner registration tokens are reusable across hosts. Forgejo registration tokens are **single-use** (consumed on registration). Generate two separate tokens in Phase 4 (one per host), or accept the second registration will fail and re-generate. | **PENDING** — Phase 4 task 5 |
| A2 | HIGH | Self-bootstrap loop: if storage's Forgejo is broken, can't push fix through Forgejo. Mitigation already exists (laptop has direct colmena-deploy capability) — make it explicit in CLAUDE.md as the canonical break-glass deploy path. | **PENDING** — CLAUDE.md update during Phase 6 |
| A3 | HIGH | `SSH_LISTEN_HOST` hardcoded to a Tailscale IP couples service config to network state. Tailscale IPs can change on re-auth. Bind `0.0.0.0` and restrict via `networking.firewall.interfaces.tailscale0.allowedTCPPorts = [ 2222 ]`. | **PENDING** — Phase 1 forgejo.nix |
| A4 | MEDIUM | `forgejo-bootstrap-mirror` oneshot needs `After = [ "sops-install-secrets.service" "forgejo.service" ]` and `Requires = [ "sops-install-secrets.service" ]` — current plan only orders against forgejo. First-deploy failure mode: secret not yet decrypted, marker still touched, never retries. | **APPLIED** (Enhancement Summary §2 — folded into bootstrap unit) |
| A5 | MEDIUM | basestar runner offline → aarch64 jobs queue indefinitely (no fail-fast on missing-runner-label). Add `timeout-minutes: 90` per job to cap walltime when runner is missing. | **PENDING** — Phase 5 workflow YAML |
| A6 | LOW | Caddy may briefly serve both `forgejo.arsfeld.one` and `git.arsfeld.one` mid-deploy as the rename takes effect. Cosmetic; first deploy after cutover resolves. | **ACCEPTED** |

### Pattern Conformance

| # | Sev | Finding | Status |
|---|-----|---------|--------|
| C1 | CRITICAL | Gateway entry missing `settings.bypassAuth = true` → Caddy double-auths OIDC callback → 401. | **APPLIED** (inline gateway edit) |
| C2 | MEDIUM | Literal `"arsfeld.one"` in forgejo.nix sketch violates `vars.domain` convention. | **APPLIED** (inline sketch edit) |
| C3 | MEDIUM | File name `forgejo.nix` vs gateway entry `git` is internally inconsistent (compare `auth.nix` → entry `auth`, `bitmagnet.nix` → entry `bitmagnet`). Rename file to `git.nix`. | **PENDING** — implementation |
| C4 | MEDIUM | Two near-duplicate runner configs (basestar + storage) violate the user's "prefer DRY" memory. Factor into `modules/constellation/forgejo-runner.nix` with `enable`, `instanceName`, `labels`, `capacity` options. Mirrors the `constellation.backrest` pattern. | **PENDING** — Phase 4 refactor |
| C5 | LOW | Empty `imports = [];` in forgejo.nix sketch is dead code. | **APPLIED** (inline sketch edit) |

### Configuration Hardening (extras)

| # | Sev | Finding | Status |
|---|-----|---------|--------|
| H1 | MEDIUM | No fail2ban / rate limiting on Forgejo HTTP login endpoint. Form-auth is the credential-stuffing target post-OIDC primary. Add `services.fail2ban` rules. | **PENDING** — Phase 2+ |
| H2 | MEDIUM | Verify Caddy security headers on `git.arsfeld.one` vhost include `Strict-Transport-Security`, `X-Frame-Options: DENY`, `X-Content-Type-Options: nosniff`. Confirm `service.COOKIE_SECURE = true` and `session.COOKIE_SECURE = true` in Forgejo settings. | **PENDING** — Phase 1 |
| H3 | LOW | Audit log retention: `journalctl` rotation may rotate out compromise evidence. Set `RetainSizeMax`/`MaxRetentionSec` on `forgejo.service`. | **PENDING** — Phase 1 |
| H4 | LOW | 2FA on the GitHub account hosting the mirror. If GitHub credentials are weaker than Forgejo, an attacker can un-archive + force-push before Forgejo reasserts. | **PENDING** — out-of-band, GitHub UI |
| H5 | LOW | Disable Forgejo SSH server's allowed key types older than ed25519 if not needed. | **PENDING** — Phase 1 |

### Simplicity Trims (most NOT applied — see "Deliberately Not Applied" above)

| # | Reviewer recommendation | Decision |
|---|-------------------------|----------|
| T1 | Cut OAuth-source registration ExecStartPost; click through web UI | **Rejected** — declarative bootstrap is the whole point of NixOS; one-time clicks rot. Apply with idempotent CLI per B2. |
| T2 | Cut `forgejo-bootstrap-mirror` oneshot; curl from laptop once | **Rejected** — same reasoning |
| T3 | Merge phases 1+2+3 into one | **Rejected** — clean per-phase Go/No-Go gates outweigh line-count savings |
| T4 | Cut "nuclear" DR scenario | **Accepted** — replaced with 1-paragraph pointer to GitHub mirror |
| T5 | Cut System-Wide Impact's Integration Test Scenarios subsection | **Accepted** — subsumed by Acceptance Criteria; remove during implementation |
| T6 | Cut Gatus monitor entirely | **Rejected** — security review identified silent-PAT-expiry as dominant risk; Gatus moved to Phase 6 (not deferred) |
| T7 | Cut Edge Cases Captured section | **Accepted** — already addressed inline in phases; remove during implementation |
| T8 | Skip stable UID/GID pinning | **Rejected** — security review confirmed sops `chown` race is real on first activation |

### Concrete Settings Additions for Phase 1 (`forgejo.nix`)

To apply during implementation — these merge with the sketch in the body:

```nix
services.forgejo.settings = {
  # ... existing settings ...

  # Action retention (per P5)
  actions = {
    ENABLED = "true";
    LOG_RETENTION = "30d";
    ARTIFACT_RETENTION_DAYS = 14;
  };

  # Mirror queue tuning (per P9)
  "queue.mirror" = {
    LENGTH = 100;
    BATCH_LENGTH = 1;
  };

  # Cleanup cron (per P5)
  "cron.cleanup_actions" = {
    ENABLED = "true";
    SCHEDULE = "@midnight";
  };

  # Logging to journald (per P4) — keeps log writes off SQLite path
  log = {
    MODE = "console";
    LEVEL = "info";
  };

  # Cookie hardening (per H2)
  service = {
    # ... existing ...
    COOKIE_SECURE = true;
  };
  session = {
    COOKIE_SECURE = true;
  };
};

# IO weighting for forgejo (per P4)
systemd.services.forgejo.serviceConfig.IOWeight = 50;
```

### Backup — simple `/var/lib` inclusion (superseded by user feedback)

Earlier deepen-pass findings (D1, D3 in the table above) recommended a `systemctl stop forgejo` quiescing hook on `CONDITION_SNAPSHOT_START`. **User overruled this as overcooked for a solo personal repo.** Final approach:

- The local-system Backrest plan on storage already covers `/var` (so `/var/lib/forgejo` rides along automatically — verify in `hosts/storage/backup/backrest-client.nix`).
- For off-site (`hetzner`, `pegasus`), confirm `/var/lib` is in `paths`; add it if those plans only target `/home` and `/mnt/storage`.
- Hot snapshots are acceptable: SQLite recovers from minor inconsistencies, and the live GitHub mirror covers git refs at sub-minute RPO.
- On restore, run `forgejo doctor check --all` to repair any metadata drift.

No `actionCommand` hooks, no `systemctl stop`, no SQLite `.backup`. Keep it boring.

### Deployment Runbook (from Go/No-Go review)

A separate Go/No-Go runbook with explicit pre-deploy checks, monitor commands, and rollback paths per phase was produced during the deepen pass. Key points (see review output for full detail):

- **Time-of-day:** Phases 1-4 any time; Phase 5 morning + 90 min wallclock; Phase 6 quiet weekday morning, never Friday/late night
- **GitHub archive (Phase 6.8):** wait at least 2 hours after first green build on master; ideally sleep on it before archiving
- **Rollback for `.github/workflows/` deletion:** `git revert <cutover-sha>` + un-archive GitHub via `gh api -X PATCH repos/arsfeld/nixos -f archived=false`. Forgejo's mirror force-pushes the GHA workflows back to GitHub. RTO ~10 min if GitHub still writable, ~15 min if archived.
- **Mirror force-pushed garbage to GitHub:** Forgejo is source of truth; re-push from laptop with `--force-with-lease` after pausing the mirror via API DELETE.

### What Was Verified Against the Codebase

The deepen pass confirmed several plan assumptions against actual repo state:

- ✅ `services.forgejo` already enabled in `hosts/storage/services/develop.nix:33-65` (will be moved out)
- ✅ `services.gitea-actions-runner.instances.basestar` already scaffolded in `hosts/basestar/services/development.nix:19-36` (`enable = false`)
- ✅ `forgejo-oidc-secret` placeholder already declared in `secrets/sops/storage.yaml:17`
- ✅ `forgejo-runner-token: ""` placeholder already in `secrets/sops/basestar.yaml:10`
- ✅ Authelia OIDC clients live in the `authelia-secrets` sops blob, NOT in nix code (per `auth.nix:117`) — Forgejo joins as the first declarative client (via the sops blob, not via a nix attribute)
- ✅ Service registry is `media.gateway.services` (in `modules/media/gateway.nix:38-106`), not `modules/constellation/services.nix` (CLAUDE.md was stale on this — fixing CLAUDE.md is a Phase 6 docs task)
- ❌ Plan referenced `rustic`; actual stack is `Backrest+restic` per `modules/constellation/backrest.nix` — corrected
- ❌ Plan referenced `hooks.before` — schema is `hooks = [ { conditions = [...]; actionCommand = "..."; } ]` — corrected
