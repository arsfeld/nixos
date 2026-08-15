# Scheduled prune and integrity checks for the backup tiers

Date: 2026-08-14

## Problem

No restic repository anywhere in the fleet has ever been pruned or integrity-checked
on a schedule, and the cold tier has never been checked at all.

Every repo in every live `config.json` — galactica, basestar, raider, pegasus —
carries `prunePolicy: null, checkPolicy: null`. This is not a misconfiguration that
drifted; `repoType` in `modules/constellation/backrest.nix` has no options to express
either policy, so no host could set them even in principle. Backrest treats the absent
value as "never":

```go
// internal/orchestrator/tasks/taskprune.go, v1.14.1
if repo.PrunePolicy.GetSchedule() == nil {
    return NeverScheduledTask, nil
}
```

`taskcheck.go` is identical. Confirmed empirically: galactica's backrest journal
contains only `backup`, `forget`, `index snapshots` and `collect garbage` tasks —
zero prune, zero check.

Three consequences:

1. **Space is never reclaimed.** `forget` runs per plan and drops snapshot
   references, but without `prune` the packs stay. galactica's `local` repo is 861 GB
   and the shared `storage` repo 445 GB, both growing monotonically.
2. **Integrity is never verified.** A corrupt pack would be discovered at restore
   time — the one moment it cannot be tolerated.
3. **It cannot be fixed from the UI.** `mergeConfigScript` preserves only `guid`,
   `modno` and `sync.identity`, so any policy set in the Backrest web UI is wiped on
   the next daemon restart.

Two coupled problems make this more than "add two fields":

- The `storage` repo is written by three separate Backrest instances (basestar,
  raider, pegasus). None of them owns prune, and all three use `keep-all` retention,
  so nothing is ever unused and prune would reclaim almost nothing anyway.
- The cold tier (`constellation.rustic`, OVH Cold Archive) generates only `backup`
  and `forget --prune` units. There is no check unit at all.

## Design

### Approach: safe-by-default, explicit opt-out

Three options were considered:

- **Per-repo opt-in** — `prune`/`check` default to `null`. Faithful to the proto and
  minimal blast radius, but reproduces exactly how this bug arose: a newly added repo
  silently gets no policy.
- **Safe-by-default** (chosen) — every repo gets a working prune and check policy by
  default; `null` disables it. The root cause here is that the absent value meant
  "never" and there was no option surface to notice that. Making the default *on*
  means the next repo anyone adds is covered automatically.
- **Module-level `defaultPrune`/`defaultCheck` plus per-repo override** — same result
  with an extra layer of knobs nobody asked for.

### `modules/constellation/backrest.nix`

`repoType` gains three options:

| Option | Type | Default |
|---|---|---|
| `prune` | `nullOr (submodule {schedule; maxUnusedPercent; maxUnusedBytes;})` | monthly schedule, `maxUnusedPercent = 10` |
| `check` | `nullOr (submodule {schedule; readDataSubsetPercent;})` | monthly schedule, `readDataSubsetPercent = null` |
| `hooks` | `nullOr (listOf attrs)` | `null` → repo-level default failure hook |

`renderRepo` emits `prunePolicy`, `checkPolicy` and `hooks`. `renderSchedule` is
reused verbatim for both new policies — `PrunePolicy` and `CheckPolicy` embed the same
`Schedule` message the plans already use, so no new schedule rendering is needed.
`check.readDataSubsetPercent = null` renders `structureOnly = true`, because the proto
models the two as a `oneof` and one arm must be set.

`mergeConfigScript` needs no change. It rebuilds from the Nix template on every start,
so the new fields flow through and UI edits remain non-authoritative.

#### Two guard rails that must be comments in the source

Both of these are silent when wrong, which is why they are called out rather than left
to the reader:

- **`maxUnusedPercent` must never be 0.** When the policy exists but the field is
  unset, Backrest passes `--max-unused 0%`, turning every prune into a full repack:

  ```go
  // internal/orchestrator/repo/repo.go, v1.14.1
  policy := r.repoConfig.PrunePolicy
  if policy == nil {
      policy = &v1.PrunePolicy{MaxUnusedPercent: 25}
  }
  ...
  opts = append(opts, restic.WithFlags("--max-unused", fmt.Sprintf("%v%%", policy.MaxUnusedPercent)))
  ```

  The 25% fallback applies only when the *whole* policy is absent, which is not the
  case once we start emitting one.

- **The failure hook moves from plan level to repo level.** Prune and check failures
  fire against the **repo's** hooks, and `renderRepo` currently emits none — so today
  those failures would be silent on ntfy. The fix is to move the existing
  `defaultFailureHook` rather than add a second one, because adding one would
  double-notify:

  - `NotifyError` prepends `CONDITION_ANY_ERROR` to every error path
    (`tasks/errors.go:46`), and the explicit `ExecuteHooks` calls in `taskbackup.go`,
    `taskprune.go` and `taskcheck.go` all include it too. So `ANY_ERROR` alone covers
    backup, forget, prune, check and index failures.
  - `TasksTriggeredByEvent` uses `firstMatchingCondition`, so one hook fires at most
    once per failure — but it iterates `repo.GetHooks()` **and** `plan.GetHooks()`.
    Keeping a plan hook and a repo hook that both match `ANY_ERROR` therefore sends
    two ntfy messages per failure.

  So: `repoType.hooks` defaults to a single `["CONDITION_ANY_ERROR"]` hook, and
  `planType.hooks` defaults to `[]`. This is a net simplification — one hook instead
  of two — and it is strictly broader coverage, since a plan-less repo (the new
  `storage` entry) has no plan hook to fall back on.

  The template keeps `{{.Plan.Id}}`. `taskrunnerimpl.go:102-106` substitutes a
  non-nil placeholder `Plan` carrying only the ID when a task has no plan, so it
  renders the real plan ID for backup/forget failures and an empty string for
  repo-scoped prune/check failures. It does not error.

### `modules/constellation/rustic.nix`

Add a check unit mirroring the existing prune unit:

- `rustic-<name>-check.service` — `ExecStart = rustic -P <name> check`, same `hardening`
  (`Nice = 10`, `IOSchedulingClass = "idle"`), same `environment` / `EnvironmentFile`,
  and `onFailure = ["backup-notify@rustic-<name>-check.service"]`.
- `checkTimerConfig` profile option (`nullOr attrs`, default `null` → manual only),
  rendered through the existing helper as `mkTimer "-check" "checkTimerConfig"`.
- `"checkTimerConfig"` **must** be added to `moduleKeys`. Anything left out of that
  list is written verbatim into the generated TOML, where opendal ignores unknown keys
  silently — the module's own comment already flags this as invisible rather than an
  error.

**No `--read-data` option is exposed, deliberately.** Verified against
`rustic_core/src/commands/check.rs`: pack contents are read only inside
`if opts.read_data {`, and `--read-data-subset` is declared `requires = "read_data"`,
so it is inert without the flag. A default `check` calls `check_packs_list` /
`check_packs_list_hot`, which use `list_with_size` — LIST operations only — and reads
snapshots, index and tree packs from the *hot* bucket. On the OVH hot/cold repo that
means no `restore-object`, no warm-up, and nothing downloaded from tape, while still
catching `NoColdFile` (an indexed pack missing from the cold bucket),
`HotPackSizeMismatchIndex`, and `HotDataPack` (a data pack misrouted into the hot
bucket).

`--read-data` against OVH would be pathological and must never be schedulable: every
pack goes through `restore-object` with `warm-up-batch = 1` and a poll that waits up
to 48 h *per pack*, across 2.9 TiB, plus retrieval billing and 7-day restore copies.

### Ownership of the shared `storage` repo

galactica takes ownership, because it hosts the REST server.

- **galactica** gains a repo `storage = /mnt/storage/backups/restic-server` with no
  plans, carrying the prune and check policies for it. The local path is used rather
  than `rest:http://galactica…:8000/` because prune is I/O-heavy and this skips the
  HTTP round trip. Verified that this path is the repo root — it contains `config`,
  `data`, `index`, `keys`, `locks`, `snapshots` — so it is the same repository the
  clients write to over REST. restic locks are objects inside the repo, so a
  local-path prune and a REST client still see each other's locks.
- **basestar, raider, pegasus** set `prune = null; check = null;` on their `storage`
  entries, with a comment naming galactica as owner. basestar's watch-only `pegasus`
  entry does the same.
- **Client retention moves off `keep-all` to `d7/w4/m6`**, matching the policy
  galactica already uses for its `hetzner` and `pegasus` plans. Without this, prune
  has nothing to reclaim.

### Schedules

One repo per day, check in the morning, prune three hours later, all owned by
galactica so there is no cross-host lock contention. Nothing lands on the 1st
(`rustic-ovh-prune`) or on a Sunday (the 02:30–07:30 backup block).

| Repo | Kind | check | prune |
|---|---|---|---|
| `local` | restic | `0 9 2 * *`, read-data 5% | `0 12 2 * *`, max-unused 10% |
| `storage` | restic | `0 9 3 * *`, read-data 5% | `0 12 3 * *`, max-unused 10% |
| `hetzner` | restic | `0 9 4 * *`, structure-only | `0 12 4 * *`, max-unused 40% |
| `pegasus` | restic | `0 9 5 * *`, structure-only | `0 12 5 * *`, max-unused 40% |
| `ovh` | rustic | first Wed of month `09:00:00`, structure-only | unchanged (`*-*-01 03:00`) |

Data-subset reads are used only where reads are free (local disk); the remote restic
repos and the cold tier get structure-only **check**. That egress-avoidance applies to
check only. `restic prune --max-unused N%` repacks partially-used packs — i.e. it
downloads and re-uploads them — independent of the check setting, so a scheduled prune
against a remote repo does transfer pack data whenever it repacks. The two remote repos
(`hetzner`, `pegasus`) therefore get a higher `max-unused` (40% vs. the local default
10%) to suppress most of that repacking; fully-dead packs are still deleted with no
download regardless of the threshold. The `ovh` check timer is pinned to the first
Wednesday of the month rather than a fixed day-of-month, because a day-of-month cron can
land on a Sunday — the same slot the `ovh` backup runs — and rustic units take no
cross-unit lock.

## Rollout

The first prune deletes real data, and the retention change deletes real history, so
this lands in stages rather than all at once.

Note on "safe-by-default" versus staging: every repo that exists today sets its
policy **explicitly**, so the module's on-by-default value never silently activates
anything in this change — it exists only to cover repos added later. Staging is
therefore achieved by splitting the commits, plus the natural lead time before the
first monthly cron fires (schedules land on days 2–6; a mid-August deploy first fires
in September).

1. Land both module changes, galactica's four explicit policies, its new `storage`
   entry, and the clients' `prune = null; check = null;` opt-outs. **Client retention
   stays `keep-all` in this step.** Deploy, then verify the new repo's guid equals
   basestar's `8f51bfd26c36f60517b376aea2dd2376c7c2042e1e6635a66aba80aba20b3174`.

   This step is not optional. `mergeConfigScript` sets `autoInitialize: true` for any
   repo with no guid, so a wrong URI would create a fresh empty repository and every
   subsequent operation would report success into the void — the same hazard
   `rustic.nix` already warns about for `rustic init`. A matching guid is proof the
   entry adopted the existing repo.
2. Run a check by hand on each of the four repos before any scheduled prune fires.
   Checks are read-only, so a failure here is information rather than damage, and a
   repo that fails its check must not be pruned.
3. In a **separate commit**, change client retention to `d7/w4/m6`. Let one forget
   cycle run and review what it marked — this is the gate before anything reclaims it.
4. Let the scheduled prune run on its cron. Confirm reclaimed space against the
   pre-prune sizes recorded in step 1 (`local` 861 GB, `storage` 445 GB).

## Out of scope

Flagged deliberately, not overlooked:

- **Per-host freshness blind spot.** galactica's REST server has no per-client
  namespacing, so `resticQuery` in `backrest.nix` returns every host's snapshots and
  `backup-status` reports the repo's newest, not this host's own. basestar, raider and
  pegasus all reported the identical `lastSnapshot` while their real latest snapshots
  differed by days. galactica's new `storage` source inherits the same aggregate view.
  The fix is a `--host` filter.
- **17 orphan `cloud` snapshots** in the `storage` repo (latest 2026-04-29). Backrest's
  forget is per-plan and no live plan owns them, so no retention policy will ever
  expire them. Removing them needs a deliberate `restic forget --host cloud`.
- **Hetzner and OVH both live.** `rustic-ovh.nix` states OVH replaces the Hetzner
  Storage Box and that its two snapshots replace the `hetzner-system` and `hetzner`
  plans exactly, but both tiers ran on 2026-08-09. Either a deliberate burn-in overlap
  or an unfinished decommission.
- **pegasus is not in the weekly sweep.** `weeklyDeploy.hosts` is tier1 only, so
  pegasus's backup health is never reported by the Sunday job.
- **`excludeIfPresent` newly takes effect on raider, basestar and pegasus.** A
  pre-existing bug in `renderPlan` emitted the field as `backupFlags`; the proto's
  json_name is `backup_flags`, so Backrest's `protojson.UnmarshalOptions{DiscardUnknown:
  true}` silently dropped it on every host that set `excludeIfPresent = [".nobackup"
  "CACHEDIR.TAG"]`. That key is now spelled correctly, which means those three hosts'
  next backups will actually start honoring `.nobackup`/`CACHEDIR.TAG` markers for the
  first time. This is a deliberate behaviour change, not a side effect to overlook: what
  each host newly excludes must be checked at deploy time (see the plan's Task 5).
