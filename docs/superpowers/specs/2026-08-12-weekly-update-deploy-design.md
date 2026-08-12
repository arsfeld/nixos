# Weekly flake update and tier-1 deploy (design)

**Date:** 2026-08-12
**Hosts:** GitHub Actions (builder), galactica (deployer), basestar + raider (targets)
**Status:** Design approved, not implemented.

## Problem

Two mechanisms are supposed to keep the fleet current. Neither works, and both fail
silently.

### GitHub `Weekly Update` — has not committed since 2026-06-07

`.github/workflows/update.yml` runs `nix flake update` every Sunday at 00:00 UTC. That
step succeeds every week. The `commit` job never runs, because it is gated on
`needs: [update, build]` with `if: ... && success()`, and `build.yml` builds **all ten
hosts** in `ciMatrix`. Any one host failing discards the whole lock update.

Last successful auto-commit: `64b3df4`, 2026-06-07. The nine Sundays since produced five
failures, three cancellations, and one more failure. Two distinct causes:

| Cause | Evidence |
|---|---|
| Eval break from the new lock | Run `31288818755` (2026-08-09) built 8/10 hosts, then raider and blackbird died: `error: 'yaru-theme' has been removed because it depended on 'gtk-engine-murrine'`, traced to `modules/constellation/desktop.nix`. Fixed by hand in `87b5888`. |
| attic narinfo timeouts | Run `31499983352` (2026-08-11, master push) failed on galactica, raider, blackbird and router with `error: unable to download 'https://attic.arsfeld.dev/system/<hash>.narinfo': Timeout was reached (28) — Connection timed out after 15001 ms`. |

Runs showing 2h01m are jobs hitting `build.yml`'s `timeout-minutes: 120`.

`attic.arsfeld.dev` resolves to `149.56.129.39` (OVH, the same provider as basestar, a
4-core ARM box). Attic is not defined anywhere in this repo, so from here it can only be
tolerated, not fixed.

Nothing notifies on failure, which is why nine weeks passed unnoticed.

### Claude routine `trig_01WR4gHeR7Hw8oSLFNsguNaL` — has never worked

Cron `0 7 * * 0`, enabled, ten recorded sessions — one per Sunday since it was created on
2026-06-05. Every session lands in an Anthropic cloud sandbox (Ubuntu 24.04, `uid=0`),
not on raider as its prompt assumes: no `nix`, no `/nix`, no `ssh` binary, no keys, and
no route to `*.bat-boa.ts.net`. The 2026-08-09 run probed for nix, found nothing, sent a
push notification, and exited after 66 seconds.

The only run that did anything (2026-06-07) merely observed that CI had already committed
the lock that morning. The routine is also configured to work on `claude/intelligent-darwin*`
branches, against this repo's master-only convention.

Net effect: zero deploys and zero backup verification, ever.

## Goals

- `flake.lock` on master stays fresh and proven to build.
- tier-1 hosts (galactica, basestar, raider) actually run master.
- Failed units and stale backups are surfaced weekly.
- Exactly one summary per week, so silence becomes a signal rather than the default.

## Non-goals

Auto-rollback, retries, canary deploys, deploying non-tier-1 hosts, and fixing attic
itself. Failures notify and wait for a human.

## Constraints

Established by measurement on 2026-08-12 unless noted.

- **No tier-1 builds on raider.** Building a tier-1 closure can OOM and take down the
  desktop session. The same reasoning applies to galactica, which runs the media stack —
  an OOM there is worse.
- **Tailscale SSH is live and keyless.** From galactica, `ssh root@raider.bat-boa.ts.net`
  and `ssh root@basestar.bat-boa.ts.net` succeed under `BatchMode=yes`, reporting
  `remote software version Tailscale` and `Authenticated ... using "none"`. `/root/.ssh`
  on galactica holds no private key. No new credential is needed for the deployer.
- **That SSH path is imperative state.** `modules/constellation/common.nix` has only
  `services.tailscale.enable = true`; no `--ssh` flag appears anywhere except
  `modules/constellation/project-vms.nix`. The tailnet ACL is out-of-repo.
- **`flake-modules/colmena.nix` sets `buildOnTarget = false`**, so the deployer builds
  unless prevented.
- **`build.yml` already caches full closures**: `attic push system ./result-<host>` for
  every matrix host, so tier-1 closures are available for substitution.
- **`constellation.backupNotify` is already available on galactica.** `rustic.nix` and
  `backrest.nix` both set `enable = mkDefault true`, and the module exposes a read-only
  `script` option taking a title and a body, reading `NTFY_BASIC_AUTH_B64` from
  `sops.secrets."ntfy-publisher-env"`.
- **`just deploy` runs `colmena apply --impure`** and follows it with a
  `multi-user.target` poke over `ssh root@<host>`.

## Architecture

Two owners, one contract.

| Owner | Responsibility | Proof of success |
|---|---|---|
| GitHub Actions | `flake.lock` on master is fresh and tier-1 builds clean; every tier-1 closure is in attic | A new `flake.lock` commit on master |
| galactica | tier-1 hosts run master, verified healthy | One ntfy summary per week |

The deployer never inspects CI status for correctness — the commit gate already encodes
it. A fresh `flake.lock` on master *means* "tier-1 built clean."

**The keystone is `NIX_CONFIG="max-jobs = 0"` on the deploy.** It makes local compilation
structurally impossible rather than merely unlikely: nix either substitutes each closure
from attic or fails with a clear error. This is what allows a deploy to run on a host
that cannot afford to build.

## Part A — GitHub changes

### A1. Gate the commit on tier-1 only

`build.yml` gains an optional `hosts` input (a JSON list). When present, the matrix is
filtered to those hosts; when absent, behavior is unchanged. `update.yml` passes the
tier-1 list, derived from the existing flake output rather than hardcoded:

```
nix eval --json '.#tiers.tier1'
```

The called workflow then succeeds exactly when galactica, basestar and raider build, so
octopi or r2s breaking no longer holds the lock hostage.

The commit message drops its `[skip ci]` suffix. The resulting push triggers `build.yml`
across all ten hosts, so the rest of the fleet is still validated and cached — after the
commit rather than as a precondition for it.

### A2. Make attic non-fatal

Both `install-nix-action` steps in `build.yml` gain:

```
fallback = true
connect-timeout = 5
download-attempts = 3
```

A stalled narinfo lookup then degrades to "build it locally, slower" instead of failing
the run.

### A3. Notify on failure

`update.yml` gains an `if: failure()` job that POSTs to the same ntfy topic the backups
use, via a new `NTFY_BASIC_AUTH_B64` repository secret holding the same credential the
hosts already use.

## Part B — `constellation.weeklyDeploy` on galactica

New module `modules/constellation/weekly-deploy.nix`, enabled only on galactica.

**Options:** `enable`, `hosts` (default `["galactica" "basestar" "raider"]`), `schedule`
(default `Sun *-*-* 06:00:00 UTC`), `repoUrl`, `stateDir` (default
`/var/lib/weekly-deploy`), `maxBackupAgeHours` (default 48).

`hosts` is a plain list, not a reference to the tier definitions: `tiers` lives in
`flake-modules/hosts.nix` as a flake output and a colmena tag, and is not visible as a
NixOS option inside a module. The colmena invocation in step 3 targets `@tier1` by tag,
so the list here is only used for the verification sweep — keep the two in sync by hand,
or the sweep silently skips a host the deploy touched.

**Unit:** `systemd.services.weekly-deploy`, `Type = oneshot`, running as root.

- `restartIfChanged = false` and `stopIfChanged = false` — galactica deploys *itself* in
  this run, and without these, activation restarts the job mid-flight.
- `MemoryMax` (12G) so a runaway evaluation dies in its own cgroup instead of taking the
  media stack with it.
- `Environment = NIX_CONFIG=max-jobs = 0`.
- `EnvironmentFile` = the `ntfy-publisher-env` secret, for the summary POST.
- `onFailure = ["backup-notify@weekly-deploy.service"]`, covering the case where the
  script itself crashes before it can send its own summary.
- `path` = colmena, git, openssh, jq, curl, nix. **Not `nix develop`** — a devshell is not
  in attic, so entering one under `max-jobs = 0` would fail. `${pkgs.colmena}/bin/colmena`
  is part of galactica's own closure, which CI built and pushed, so it is guaranteed
  present.

**Timer:** `OnCalendar` per `schedule`, `Persistent = true`, `RandomizedDelaySec = 600`.
The `UTC` suffix in a calendar spec needs systemd ≥ 252; confirm with
`systemd-analyze calendar "Sun *-*-* 06:00:00 UTC"` on galactica before relying on it,
since a silently-local interpretation would drift the run relative to CI.

**Script:**

1. **Sync.** Clone-or-fetch `https://github.com/arsfeld/nixos.git` into
   `${stateDir}/nixos` (public repo, no credentials), then `git reset --hard origin/master`.
   The clone is machine-owned and holds no user data.
2. **Precondition.** Query the GitHub REST API for completed runs at that commit; require
   the `Build & Cache` run to have concluded `success`. If it has not, notify
   "skipped: master not green (`<sha>`)" and exit 0. This is what keeps step 3 from
   failing noisily on a commit CI has not finished caching. Unauthenticated API access is
   60 requests/hour per IP — ample for weekly use.
3. **Deploy.** `colmena apply --impure --on @tier1`, under `max-jobs = 0`. Colmena
   continues past a node that fails, so per-host best effort falls out of its own
   behavior rather than needing a loop. Whether `--impure` survives is settled by the
   pre-flight check in the verification plan below.
4. **Poke.** `ssh root@<host> systemctl start multi-user.target` per host, matching
   `just _poke-targets`.
5. **Verify.** Per host, over Tailscale SSH: `readlink -f /run/current-system`,
   `systemctl --failed --no-legend`, and `backup-status` (Part C).
6. **Report.** Write the collected results to `${stateDir}/last-run.json` and send one
   ntfy message through `config.constellation.backupNotify.script`. Send it every week,
   green or not. Anything wrong leads the body and raises priority.

The unit exits 0 once the summary is sent, even when individual hosts failed — the
summary is the signal, and `OnFailure` covers only unexpected crashes.

## Part C — the `backup-status` contract

The deployer must not know how any given host backs up. Instead, a new module
`modules/constellation/backup-status.nix` defines:

```nix
constellation.backupStatus.sources = [ { name = "..."; command = "..."; } ];
```

and renders a single `backup-status` executable onto the system PATH that runs every
registered source and emits one JSON array. `rustic.nix` appends one source per profile;
`backrest.nix` appends one per repo. Aggregating through a list rather than each module
installing its own script matters because galactica runs **both** rustic and backrest.

**Schema**, one object per repo or profile:

```json
{ "name": "hetzner", "kind": "restic", "lastSnapshot": "2026-08-10T04:31:00Z",
  "ageHours": 41.2, "ok": true, "error": null }
```

`ok` is `ageHours <= maxBackupAgeHours`. A source that cannot be queried reports
`ok: false` with `error` set, never a crash.

- **rustic sources** run the `rustic-<profile>` wrapper the module already installs
  (`rustic-<name> snapshots --json`) and take the maximum snapshot `time`.
- **backrest sources** run `restic -r <uri> snapshots --latest 1 --json` with
  `RESTIC_PASSWORD_FILE` and the repo's declared `env`, all of which `backrest.nix`
  already holds in `renderRepo`.

This closes the gap the old routine's prompt called out explicitly: a live daemon with
nine-day-old snapshots reports `ok: false`, where a `systemctl is-active` check would
report healthy.

## Part D — cleanup

- **Delete the Claude routine** `trig_01WR4gHeR7Hw8oSLFNsguNaL`. Nothing depends on it.
- **Declare Tailscale SSH.** Add `services.tailscale.extraSetFlags = ["--ssh"]` to
  `common.nix`, so the auth path this whole design rests on survives a host re-auth or
  reinstall. `extraSetFlags` is preferred over `extraUpFlags` because it reapplies on
  every activation. This matches what is already imperatively true fleet-wide; the ACL
  governing who may use it stays out-of-repo.
- **Generalize the `backup-notify@` title.** Its `ExecStart` currently hardcodes
  `"Backup failed on <host>: %i"`. Once `weekly-deploy` points `OnFailure` at it, that
  wording is wrong for a non-backup unit. Change it to a neutral `"<host>: %i failed"`;
  the module already serves two unrelated callers (rustic and backrest), so the title was
  never carrying backup-specific meaning.

## Failure matrix

| Situation | Behavior |
|---|---|
| New lock breaks eval in CI | No commit; ntfy from `update.yml`; master keeps the old lock; the weekly deploy is a no-op |
| attic stalls during CI | `fallback = true` builds locally; slower, still green |
| master not green at deploy time | Deploy skipped, ntfy says so, nothing touched |
| A host is unreachable | Colmena marks that node failed and continues; summary flags it |
| A closure is missing from attic | `max-jobs = 0` errors for that node only; others proceed; summary flags it |
| Failed unit or stale backup found | Summary leads with it at raised priority |
| The script itself crashes | `OnFailure` fires `backup-notify@weekly-deploy` |

## Verification plan

- **Pre-flight (blocking):** confirm colmena's evaluated toplevel for each tier-1 host
  matches the path CI built and pushed. `just deploy` passes `--impure`, and if impure
  evaluation yields different derivations, `max-jobs = 0` fails on every host and the
  whole design collapses. Nothing in the flake appears to require it — the only
  `builtins.readDir` calls (`flake-modules/hosts.nix:10`,
  `modules/refind-theme-regular.nix:82`) are on in-flake paths, which are pure. If the
  paths differ, drop `--impure` and re-check.
- `systemctl start weekly-deploy` on galactica out-of-band; expect a summary within
  minutes and zero local builds in the journal.
- Point the precondition check at a commit with a failed run; expect the skip path.
- Set `maxBackupAgeHours = 0`; expect every source to report `ok: false`.
- Trigger `update.yml` via `workflow_dispatch`; expect a `flake.lock` commit when tier-1
  is green, and a full ten-host `build.yml` run on the resulting push.

## Risks

- rustic's and restic's JSON shapes must be confirmed against the installed versions at
  implementation time.
- backrest repos with `rclone:` URIs may need rclone configuration in root's environment
  to answer snapshot queries. Those sources report `error` rather than blocking the run.
- attic remains a single point of flakiness. By design the deploy skips rather than
  builds when a closure is missing, so attic degradation costs freshness, not stability.
- Deploying raider unattended restarts services on a desktop that may be in use. This is
  unchanged from the behavior the old routine intended.
