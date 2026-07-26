---
date: 2026-04-27
topic: self-host-forgejo
---

# Self-Host Forgejo + Forgejo Actions on Storage

## What We're Building

Move the primary location of this NixOS config repo from GitHub to a self-hosted **Forgejo** instance running on the `storage` host, with self-hosted CI via **Forgejo Actions** runners on `storage` (x86_64) and `basestar` (aarch64). GitHub becomes a read-only public mirror, automatically updated from Forgejo on every push to `master`.

The repo will be reachable at `git.arsfeld.one` via the existing storage cloudflared wildcard tunnel. CI will replicate today's `build.yml` flow (closures → Attic), add `nix flake check` + `just fmt --check`, and run a weekly flake-input bumper. Auto-deploy is explicitly out of scope.

## Why This Approach

**Git host alternatives considered:**

- **Full migration off GitHub** — rejected: loses public discoverability and the implicit DR fallback.
- **Primary on storage + GitHub mirror** — *chosen*: source of truth lives at home; GitHub stays a live read-only copy.
- **Primary on storage + GitHub archive** — rejected: same as full migration, with a stale snapshot.
- **GitLab CE** — rejected: too heavy for solo personal infra; resource and ops overhead doesn't pay back.
- **Sourcehut** — rejected: mailing-list workflow doesn't match how we work.
- **Bare repo on storage** — rejected: no CI, no web UI, no PR review surface.

**Forgejo vs Gitea:** Forgejo is the actively-maintained community fork; Gitea has drifted toward a commercial direction since 2023. Both ship with Actions; Forgejo's NixOS module (`services.forgejo`) is mature and well-supported in nixpkgs.

**CI alternatives considered:**

- **Hydra** — rejected: heavyweight, very different ergonomics from GitHub Actions, painful for the simple closure-build-and-push workflow we have.
- **Hercules CI** — rejected: not a self-hosted-first model.
- **Self-hosted GitHub Actions runners on storage** — rejected: still depends on GitHub for orchestration.
- **Forgejo Actions** — *chosen*: workflows are GitHub-Actions-compatible, native to Forgejo, runners run on the host system with full access to the `/nix` store and the existing remote-builder topology.

## Key Decisions

- **Forgejo on storage, `git.arsfeld.one` via cloudflared.** Matches the existing pattern for `*.arsfeld.one` services. Reachable from anywhere without joining the tailnet, so a fresh laptop can clone.
- **SQLite, not Postgres.** Solo user, low write volume; one less moving part to operate and back up.
- **Authelia OIDC for web SSO.** Same pattern as every other internal service; LLDAP backs Authelia, so users continue living there. Git-over-SSH bypasses this entirely (key-based, as God intended).
- **Runners on the host system, not Docker.** Nix workloads benefit massively from access to the host `/nix` store and the existing remote-builder topology (basestar already builds aarch64 for storage).
- **Two labeled runners:** storage labeled `x86_64-linux`, basestar labeled `aarch64-linux`. Workflows target arch via `runs-on:`.
- **Mirror `master` to GitHub on every push.** Forgejo's built-in push mirror feature; GitHub becomes the read-only public face and a live off-site backup.
- **Hard cutover.** No long parallel-running CI period. Mitigation: verify all three workflows green on a feature branch in Forgejo *before* deleting `.github/workflows/`.
- **CI scope:** replicate today's `build.yml` + add `nix flake check` + `just fmt --check` + weekly flake-input bumper. **Auto-deploy explicitly out of scope** — colmena from the laptop is already low-friction, and CI-driven self-deploy creates a circular dependency that bites the first time storage is broken.
- **Workflows in `.forgejo/workflows/`.** Explicit native path; renaming makes the cutover obvious in git history. (Forgejo also reads `.github/workflows/`, but moving them is the right signal.)
- **Backup is mandatory.** Forgejo data is now source-of-truth. Add `/var/data/forgejo` to the existing rustic/restic config.

## Risks Flagged

1. **Hard-cutover risk** — Forgejo Actions has small differences from GitHub Actions (e.g., available marketplace actions, `cache` action implementation, Attic auth flow). Mitigation: trial run on a branch before deleting `.github/workflows/`.
2. **Storage as source of truth** — single point of failure for repo writes. GitHub mirror is the live backup; rustic snapshots cover catastrophic data loss.
3. **Authelia outage** — would block Forgejo *web UI* sign-in. Git-over-SSH still works. Acceptable.
4. **Cloudflared tunnel for SSH** — git+ssh doesn't traverse cloudflared cleanly. Need to expose SSH separately (Tailscale, or direct WAN port). Open question below.

## Open Questions

- **SSH exposure.** cloudflared handles HTTPS only. Options: (a) Tailscale-only SSH (push/pull from anywhere on tailnet, no public WAN), (b) public SSH on a non-22 port via direct WAN forward, (c) cloudflared TCP tunnel for SSH. Decision deferred to plan phase.
- **First admin bootstrap.** `services.forgejo` initial-setup token vs fully declarative admin user via `services.forgejo.settings`. Plan should pick one.
- **Authelia OIDC claim mapping.** Specific scope set and admin-role mapping for Forgejo. Plan should specify.
- **Auto-update PR target.** Weekly bumper opens PRs in Forgejo (now source of truth) — confirmed by elimination, but worth restating.
- **Backup cadence.** Daily is the existing baseline; consider hourly given the new criticality.
- **`.forgejo/workflows/` vs `.github/workflows/` rename timing.** Rename in the same commit that deletes GHA, or earlier.

## Out of Scope (Deliberately)

- Forgejo OCI/package registries
- Forgejo Releases workflow
- Postgres backend
- Multi-user beyond the admin account
- Auto-deploy via colmena from CI
- Dependabot/Renovate for non-flake dependencies

## Next Steps

→ `/ce:plan` for implementation details
