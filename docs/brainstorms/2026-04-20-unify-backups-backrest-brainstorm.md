---
date: 2026-04-20
topic: Unify restic/rustic backups under Backrest for central observability
status: brainstorm
---

# Unify Backups Under Backrest

## What We're Building

Replace the two parallel backup stacks (`services.rustic` via the
`constellation.backup` module + native `services.restic.backups` on
storage and basestar) with a single per-host **Backrest** deployment.
Every host that currently backs up moves to Backrest; each instance is
exposed via the existing Caddy gateway and reports success/failure to
the local **ntfy** server for a single "did last night's backups pass?"
feed.

This is a tooling + observability unification, not a re-architecture of
what gets backed up, where it goes, or how often.

## Why This Matters

**Today's fragmentation:**

- Two tools with different config shapes doing the same job:
  `services.rustic.profiles` (TOML-ish, one profile per host via the
  `constellation.backup` module) vs. `services.restic.backups` (the
  native nixpkgs module, hand-rolled per host).
- basestar runs **both** — a weekly rustic push of `/var/lib /home
  /root` to storage, *and* a daily native-restic push of `/var/lib
  /root` to `restic.arsfeld.one` (storage's public REST endpoint).
  Overlapping scope, two sources of truth, two systemd unit families.
- Three hosts currently enable `constellation.backup` (basestar,
  pegasus, **raider**); storage runs five hand-rolled restic profiles.
  No single file or command answers "who backs up what, where, on what
  schedule."

**Today's observability gap:**

- No dashboard, no central status surface, no single alert channel.
- The aspirational "Monitoring" section in `docs/architecture/backup.md`
  is not implemented.
- Failure detection relies on systemd unit status + whatever
  `OnFailure=` email hook happens to exist per host. In practice a host
  that silently stops backing up for weeks is plausible.

**Why Backrest specifically:**

- Single Go binary, wraps restic, speaks the same repo format — no
  reseed required.
- Web UI for run history, logs, manual runs, prune/check scheduling.
- First-class hooks (ntfy, webhook, SMTP, shell) per plan, per event
  type. Drops directly onto the existing `ntfy.arsfeld.one` with the
  `ntfy-publisher-env` credential already provisioned across hosts.
- Active upstream, packaged in nixpkgs.

## Scope

### In scope (Phase A)
- New `modules/constellation/backrest.nix` wrapping the nixpkgs
  `services.backrest` module with a minimal per-host option surface.
- **storage:** migrate all 5 existing restic profiles (`nas`,
  `hetzner-system`, `hetzner`, `pegasus-system`, `pegasus`) to Backrest
  plans. Same repos, same passwords, same schedules, same exclusions,
  same retention. No reseed.
- **basestar:** collapse the rustic profile (weekly →
  `storage.bat-boa.ts.net:8000`) *and* the native restic profile (daily
  → `restic.arsfeld.one/basestar`) into one Backrest plan writing to
  storage's REST server. Picks daily cadence (finer resolution wins)
  and the superset of paths.
- **pegasus:** migrate the `constellation.backup` rustic profile to a
  Backrest plan, same destination (storage's REST server), same scope.
- **Caddy portal:** register per-host subdomains (e.g.
  `backrest-storage.arsfeld.one`, `backrest-basestar.arsfeld.one`,
  `backrest-pegasus.arsfeld.one`) via the existing service registry,
  behind Authelia. Backrest's built-in auth is weak; Authelia is the
  authoritative gate.
- **Notification sink:** every Backrest plan posts to
  `ntfy.arsfeld.one/backups` on failure, and optionally on success for
  the first N runs during validation. Uses the existing
  `ntfy-publisher-env` secret.
- **Retire the rustic module** (`modules/rustic.nix` +
  `modules/constellation/backup.nix`) after all clients are migrated.
- **REST servers unchanged.** `services.restic.server` on storage and
  pegasus stay exactly as they are.

### Out of scope (explicit non-goals)
- **No reseed.** Repos stay 1:1 with today's layout. The
  `*-system` vs user-data repo split on hetzner/pegasus is preserved
  even though merging them would dedupe better — that's Phase B.
- **No change to retention policies.** Exact `--keep-*` flags carry
  over unchanged.
- **No new hosts.** blackbird, r2s, raspi3, router, octopi don't back
  up today and won't start backing up as part of this work.
- **No change to what gets backed up.** The exclusion lists on
  storage's 5 profiles carry over verbatim.
- **No auth added to the restic REST servers.** They stay `--no-auth`
  on Tailscale. Only the Backrest UIs get Authelia.
- **Not a backup-policy rethink.** RTO/RPO targets, disaster-recovery
  runbooks, restore-test cadence — all out of scope for this work.

## Key Decisions

### Topology: per-host Backrest + central notifier
Backrest runs per host, backing up local paths. Observability is
unified at the *notification* layer (one ntfy topic for all hosts), not
at the UI layer. Caddy portal gives one-bookmark access to every host's
UI but does not aggregate.

Rejected alternative: "hub-only on storage, other hosts push via
restic." That's essentially the status quo — Backrest can't snapshot
remote filesystems, so the other hosts still need *something* running
locally. A hub-only deployment would leave basestar/pegasus/raider with
no dashboard or alerting.

### Migration: parallel-run then cutover, per host
For each host: add the Backrest plan alongside the existing timer,
disable the rustic/restic timer in the same commit, let one full
cycle run, verify the ntfy notification arrives, then move to the next
host. basestar goes first (smallest blast radius, already fragmented
so any unified state is an improvement). storage goes last (biggest
blast radius; 5 profiles).

### Repo layout: 1:1, no merge
Today's repos stay untouched. Backrest imports each existing repo with
its current password file and runs plans against it. This means:
- Five repos on storage's side: `/mnt/storage/backups/restic` (local
  nas), `rclone:hetzner:backups/restic-system`,
  `rclone:hetzner:backups/restic`,
  `rest:http://pegasus.bat-boa.ts.net:8000/` (×2 with
  `--repository-file` / path scoping).
- basestar + pegasus continue pushing to
  `rest:http://storage.bat-boa.ts.net:8000/` (internal) or
  `rest:https://restic.arsfeld.one/` (public tunnel) — pick one and
  stick to it; the current state has basestar using both and that's
  part of what's being fixed.

**Open question:** basestar today uses the *public* cloudflared
endpoint `restic.arsfeld.one/basestar` for its native-restic push but
the *Tailscale* endpoint `storage.bat-boa.ts.net:8000` for its rustic
push. Planning should pick one. Tailscale is the right default
(lower-latency, no cloudflared dependency, existing trust model for
other clients).

### Notifications: ntfy first, email as safety net
Primary: `ntfy.arsfeld.one/backups` topic (auth via existing
`ntfy-publisher-env`). One topic across all hosts, each notification
tagged with hostname + plan name. Failures always notify; successes
notify only during validation or on first-run-after-failure.

Secondary: SMTP `OnFailure=` hook kept on the systemd units Backrest
generates, as a belt-and-suspenders fallback for when ntfy itself is
down.

### Auth on the Backrest UI: Authelia only
Backrest's built-in username/password is disabled (or set to a strong
throwaway) and the Caddy vhost enforces Authelia. This matches the
pattern for other internal dashboards.

## Hosts and Current State

| Host     | Current backup mechanism                                    | After Phase A                                          |
|----------|--------------------------------------------------------------|--------------------------------------------------------|
| storage  | 5 `services.restic.backups` profiles, 1 REST server          | 5 Backrest plans, same REST server untouched           |
| basestar | `constellation.backup` (rustic, weekly) + 1 native restic (daily) | 1 Backrest plan, daily, to storage                |
| pegasus  | `constellation.backup` (rustic, weekly) + 1 REST server      | 1 Backrest plan, weekly, to storage + same REST server |
| raider   | `constellation.backup` (rustic, weekly)                      | See Open Questions #1                                  |

## Files In Scope

- **New:** `modules/constellation/backrest.nix` — per-host module with
  `plans`, `repos`, `notifications` options. Wraps `services.backrest`.
- **New:** `hosts/storage/backup/backrest.nix` — storage-specific
  plans (the five existing restic profiles, re-expressed).
- **Modify:** `hosts/basestar/configuration.nix` — drop
  `constellation.backup.enable`. Replace `hosts/basestar/backup.nix`
  contents with Backrest plan.
- **Modify:** `hosts/pegasus/configuration.nix` — drop
  `constellation.backup.enable`, add Backrest plan.
- **Modify:** `hosts/storage/backup/default.nix` — remove
  `./backup-restic.nix` import once migration is complete.
- **Delete (final step):** `modules/rustic.nix`,
  `modules/constellation/backup.nix`,
  `hosts/storage/backup/backup-restic.nix`.
- **Modify:** `modules/constellation/services.nix` — register the
  `backrest-<host>` subdomains with `bypassAuth = false` (Authelia on).
- **Modify:** `modules/media/gateway.nix` (if needed) — no change
  expected; the existing service-registry flow should handle new
  subdomains automatically.
- **Secrets:** no new secrets needed. Reuse
  `sops:common.yaml/restic-password`, existing `hetzner-webdav-env`,
  `hetzner-storagebox-ssh-key`, `ntfy-publisher-env`. New optional:
  per-host `backrest-instance-id` if the backrest module requires one.
- **Docs:** refresh `docs/architecture/backup.md` — its current
  "Rustic" framing is stale. Post-Phase-A, it should describe
  Backrest + the five repos + the ntfy feed.

## Open Questions

1. **raider in Phase A, or deferred?** raider (desktop workstation)
   currently runs `constellation.backup.enable = true` weekly to
   storage. Three choices:
   - (a) Include in Phase A alongside storage/basestar/pegasus.
   - (b) Retire raider's backup entirely — desktop state is mostly
     reproducible from the nixos config + dotfiles; /home is already
     on Nextcloud/Seafile for the important bits.
   - (c) Keep raider on rustic temporarily while the module is still
     present, migrate as a fast follow-up.

   Recommendation: (a). raider has home-dir state worth protecting and
   the migration is near-zero marginal work once the Backrest module
   exists.

2. **Endpoint choice for basestar → storage.** Today it uses both
   `storage.bat-boa.ts.net:8000` (rustic path) and
   `restic.arsfeld.one` (native-restic path). Planning should pick
   one. Recommendation: Tailscale, consistent with pegasus and raider.

3. **Does pegasus's REST server stay `--no-auth`?** It accepts pushes
   from storage only (over Tailscale) and has no other clients. Status
   quo is fine; flagged only because the Backrest UI getting Authelia
   might prompt the question.

4. **Notification noise budget.** How chatty should the ntfy feed be?
   Defaults proposed: failure = always, success = first-run + first-
   after-failure. Worth a pass during planning to make sure this
   doesn't evolve into "I ignore the backups topic because it pings
   every night."

5. **Backrest's own persistence.** Backrest stores its config, run
   history, and operation logs in a state directory. That state
   should itself be on a backed-up path (`/var/lib/backrest`) so a
   host rebuild doesn't lose the plan definitions — but the plans are
   also declared in Nix, so this is mostly about run history.
   Planning should confirm the default state path is covered by
   Backrest's own system plan (self-backup) or accept the loss.

6. **Systemd-triggered vs Backrest-internal scheduler.** Backrest has
   its own cron-like scheduler in-process. nixpkgs' `services.backrest`
   module may or may not expose this cleanly vs. systemd timers.
   Preference: Backrest's internal scheduler (so the UI's "next run"
   display is accurate), but confirm at plan time that failures still
   propagate to systemd-level alerts.

## Phase B (Deferred, Not In This Work)

Recorded for context; do not pull into Phase A.

- **Merge `*-system` + user-data repos per destination.** Today
  hetzner and pegasus each have two repos (system / user). Merging to
  one repo per destination with two plans gives better dedup and
  simpler retention, at the cost of a one-time reseed.
- **Cross-host repo integrity reports.** A weekly scheduled
  `restic check --read-data-subset` surfaced via ntfy.
- **Restore drills.** Automated monthly "can we actually restore?"
  test — currently a manual TODO in the backup doc.

## Success Criteria

Phase A is done when:

1. `services.rustic` and the `modules/rustic.nix` + `constellation.backup`
   modules are deleted from the repo.
2. Every host that backed up before Phase A still backs up on the same
   (or finer) cadence, into the same repos, with no snapshot loss.
3. Every Backrest plan run posts to `ntfy.arsfeld.one/backups` on
   failure, verified by forcing at least one failure per host.
4. All three Backrest UIs are reachable behind Authelia via their
   Caddy subdomains from any trusted device.
5. `docs/architecture/backup.md` reflects the new Backrest-based
   topology — no stale `services.rustic` examples.

## Next Step

Run `/ce-plan` to turn this into a concrete implementation plan, or
resolve Open Question #1 (raider scope) first since it changes the
host list.
