---
title: Unify backups under Backrest for central observability
type: feat
status: active
date: 2026-04-20
origin: docs/brainstorms/2026-04-20-unify-backups-backrest-brainstorm.md
---

# Unify Backups Under Backrest

## Overview

Replace the two parallel backup stacks — `services.rustic` (via the
`constellation.backup` module) and hand-rolled `services.restic.backups`
— with a single `constellation.backrest` module. Every host that backs
up today migrates: **storage, basestar, pegasus, raider**. Each runs
its own Backrest instance (web UI + scheduler wrapping restic), its UI
fronted by Caddy + Authelia on storage's gateway, its failures posted
to `ntfy.arsfeld.one/backups` for a single unified feed. Existing restic
repositories are preserved 1:1 — no reseed. The rustic module and the
hand-rolled restic profiles are deleted once all four hosts are
migrated.

## Problem Frame

See origin doc for motivation. Summarized: today's backups are split
across two tools with two config shapes, basestar runs both against
overlapping scope, there is no dashboard or alerting, and "did every
host's nightly run succeed" has no single answer. The fragmentation
(see origin: `docs/brainstorms/2026-04-20-unify-backups-backrest-brainstorm.md`,
"Today's fragmentation") is the primary pain; the missing observability
surface is the secondary pain. Both are solved by a per-host Backrest
deployment with ntfy notifications unified.

## Requirements Trace

Pulled from origin doc's "Success Criteria" section:

- **R1.** `services.rustic`, `modules/rustic.nix`, and
  `modules/constellation/backup.nix` are deleted from the repo.
- **R2.** Every host that backed up before Phase A still backs up on
  the same or finer cadence into the same repositories with no
  snapshot loss.
- **R3.** Every Backrest plan posts to `ntfy.arsfeld.one/backups` on
  failure. Verified by forcing at least one failure per host.
- **R4.** All four Backrest UIs are reachable behind Authelia via
  their Caddy subdomains from any trusted device.
- **R5.** `docs/architecture/backup.md` reflects the new topology; no
  stale `services.rustic` examples remain.
- **R6.** basestar no longer runs two overlapping backup stacks.
  Rustic + native-restic collapse into one Backrest plan.

## Scope Boundaries

- **No reseed.** Today's repository layout stays 1:1. Merging
  `*-system` and user-data repos per destination stays deferred.
- **No change to retention policies or exclusion lists.** `--keep-*`
  flags and exclude globs carry over verbatim.
- **No new hosts.** blackbird, r2s, raspi3, router, octopi don't back
  up today and won't start as part of this work.
- **No auth added to the restic REST servers.** They stay
  `--no-auth` on Tailscale on storage and pegasus.
- **Not a backup-policy rethink.** RTO/RPO targets, disaster-recovery
  runbooks, restore-test cadence — out of scope.

### Deferred to Separate Tasks

- **Merge `*-system` + user-data repos per destination** for better
  dedup. Requires one-time reseed on hetzner and pegasus.
- **Scheduled `restic check --read-data-subset` integrity reports**
  surfaced via ntfy.
- **Automated monthly restore drills.**

## Context & Research

### Relevant Code and Patterns

- `modules/rustic.nix` — current rustic wrapper module; its option
  shape (`profiles.<name>` with `repository`, `backup.snapshots`,
  `timerConfig`, `environmentFile`) is the reference for the new
  module's ergonomics.
- `modules/constellation/backup.nix` — opt-in wrapper that emits a
  `services.rustic.profiles.storage` block. After this plan, gets
  deleted; its callers (`basestar`, `pegasus`, `raider`) switch to
  `constellation.backrest`.
- `hosts/storage/backup/backup-restic.nix` — five hand-rolled
  `services.restic.backups` profiles; these become the five Backrest
  plans on storage. Exclude lists (`systemExcludes`, `userExcludes`)
  are the canonical lists the new module consumes verbatim.
- `hosts/basestar/backup.nix` — native-restic profile pointing at
  `rest:https://restic.arsfeld.one/basestar`; collapses into one
  Backrest plan with the combined rustic paths.
- `modules/media/gateway.nix` + `modules/media/__utils.nix` — service
  registration pattern. Each entry gets a Caddy vhost at
  `<name>.arsfeld.one` with Authelia in front when
  `settings.bypassAuth = false` (default).
- `hosts/storage/services/ntfy.nix` — local ntfy at
  `ntfy.arsfeld.one`, auth lockdown in place, publisher credential
  at sops secret `ntfy-publisher-env`.
- `hosts/basestar/services/gatus.nix:140-147` — existing Go-template-
  style `Authorization: Basic ${NTFY_BASIC_AUTH_B64}` pattern; useful
  reference for how other services template the ntfy auth into
  headers from a sops env file.
- `hosts/storage/services/infra.nix` — cross-host reverse-proxy
  pattern (grafana etc.); template for `backrest-<host>.arsfeld.one`
  entries routing from storage's Caddy to remote backrest instances.

### Institutional Learnings

- `docs/solutions/` does not exist in this repo. No prior learnings
  to carry forward. Brainstorms in `docs/brainstorms/` and previously
  executed plans in `docs/plans/` are the available institutional
  memory.
- The local ntfy plan (`docs/plans/2026-04-15-feat-secure-local-ntfy-plan.md`)
  is implemented; `ntfy-publisher-env` secret shape already includes
  `NTFY_PUBLISHER_USER`, `NTFY_PUBLISHER_PASS`, and
  `NTFY_BASIC_AUTH_B64`. All three publisher hosts in this plan
  (storage, basestar, pegasus) already load this secret; raider
  does not yet.

### External References

Primary researched artifact is Backrest's config schema and runtime
behavior:

- **Backrest README + cookbooks** —
  https://github.com/garethgeorge/backrest ;
  https://github.com/garethgeorge/backrest/blob/main/docs/src/cookbooks/reverse-proxy-examples.md
- **Config proto (authoritative schema)** —
  https://github.com/garethgeorge/backrest/blob/main/proto/v1/config.proto
- **Hooks docs** —
  https://garethgeorge.github.io/backrest/docs/hooks
- **Shoutrrr ntfy URL format** — used for ntfy hook:
  https://containrrr.dev/shoutrrr/v0.8/services/ntfy/
- **Env/paths** —
  https://github.com/garethgeorge/backrest/blob/main/internal/env/environment.go

Key findings that shape the module design:

1. No `services.backrest` module in nixpkgs — the package
   (version 1.10.1) exists but we must build the wrapper.
2. Backrest **mutates its own `config.json` at runtime** (bumps
   `modno`, populates `guid` on repos from `restic cat config`).
   The config file cannot live in the Nix store.
3. No first-class ntfy hook type. Use `actionShoutrrr` with a
   `ntfy://user:pass@host/topic?scheme=https` URL.
4. Set `BACKREST_RESTIC_COMMAND=${pkgs.restic}/bin/restic` to stop
   Backrest from downloading its own restic binary into the data
   directory.
5. Importing an existing restic repo with `autoInitialize: false`
   works cleanly; first connect indexes snapshots into the Backrest
   SQLite oplog — no reseed.
6. Multi-host to one repo: each instance must set a distinct
   `config.instance` (used as restic `--host` tag).
7. Behind Authelia: set `auth.disabled: true` in Backrest config,
   forward-auth works without websocket carve-outs.

## Key Technical Decisions

- **Module pattern mirrors `modules/rustic.nix`.** A single
  `modules/constellation/backrest.nix` that accepts `plans`, `repos`,
  and `hooks` attrsets, emits a systemd service, and generates
  `config.json` from Nix attrs. Keep the option surface thin — don't
  re-create Backrest's full proto schema.
- **Config-render-every-deploy.** Nix renders a pristine
  `config.json` template into the Nix store, and `ExecStartPre`
  (with the service stopped) runs envsubst to produce
  `/var/lib/backrest/config.json`, overwriting any runtime
  mutations. Since we disable Backrest's own auth (see below) there
  is no UI-created state worth preserving. Trade-off: Backrest
  re-derives `guid` on each repo on first startup after a deploy
  that changes a repo URL (cheap — one `restic cat config` call).
  Operators should treat the UI as read-only; any retention or
  prune-policy tweaks go into Nix, not the UI.
- **Per-host instance identity.** `config.instance` is always set to
  the hostname; restic uses this as `--host` tag so snapshots on
  shared repos stay attributable.
- **Auth: Authelia only.** Every Backrest instance sets
  `auth.disabled: true`. The Caddy vhost for
  `backrest-<host>.arsfeld.one` enforces Authelia via the gateway's
  default `bypassAuth = false`.
- **Binding: Tailscale-only.** Each Backrest binds to
  `0.0.0.0:9898`, firewall opens 9898 on `tailscale0` only.
  Cross-host proxy from storage's Caddy traverses Tailscale.
- **Notifications: failure-only ntfy via `actionWebhook`.** One
  module-level default hook. Fires on
  `CONDITION_ANY_ERROR` and `CONDITION_SNAPSHOT_ERROR`. **No
  success notifications in Phase A.** Operators confirm green state
  via the Backrest UI. Rationale: Backrest has no native
  "success-after-error" primitive; proposed shell-hook workarounds
  relied on undocumented processlog paths and added complexity that
  served no stated requirement.
  - **Transport: `actionWebhook`, not `actionShoutrrr`.** The
    webhook posts to `https://ntfy.arsfeld.one/backups` with an
    `Authorization: Basic ${NTFY_BASIC_AUTH_B64}` header (same
    pattern as `hosts/basestar/services/gatus.nix:140-147`). This
    keeps the publisher credential **out** of Backrest's UI and
    processlogs. The alternative (`actionShoutrrr` with
    `ntfy://user:pass@...`) would embed credentials in the URL, and
    Backrest's UI renders hook configurations verbatim.
  - Body is a Go-template including hostname, plan id, and error
    message.
- **Scheduler: Backrest internal.** Cron expressions on servers
  (`CLOCK_UTC`), `CLOCK_LAST_RUN_TIME` interval on raider (laptop,
  often suspended). No systemd timers for plan execution. This
  sidesteps the rustic module's timer-unit approach and keeps
  "next run" visible in the Backrest UI.
- **Secret templating.** Repo passwords and credential env vars come
  from sops, delivered via `EnvironmentFile=` on the systemd unit.
  `ExecStartPre` runs `envsubst -no-unset -no-empty` against a
  `config.json.tmpl`, rendering `${RESTIC_PASSWORD}`,
  `${HETZNER_WEBDAV_PASSWORD}`, `${NTFY_BASIC_AUTH_B64}` etc. into
  `/var/lib/backrest/config.json`. The `-no-unset` and `-no-empty`
  flags cause envsubst to exit non-zero if any referenced variable
  is undefined or empty — a missing secret fails service start
  rather than silently producing a broken config. (Research finding:
  bash `set -u` does NOT propagate into envsubst's own substitution;
  the flags are the correct mechanism.) Directory hardening:
  `StateDirectory=backrest` + `StateDirectoryMode=0700`.
- **Service user: root.** Matches every existing backup service
  (`services.rustic`, `services.restic.backups`). The systemd unit
  starts as root, reads `EnvironmentFile=` (including the
  0400-owner-arosenfeld `ntfy-publisher-env` — works because the
  unit is root at read time), then execs Backrest.
- **restic binary.** Point Backrest at `${pkgs.restic}/bin/restic`
  via `BACKREST_RESTIC_COMMAND`. Prevents Backrest from downloading
  its own binary into `/var/lib/backrest` at runtime.
- **Migration sequencing: pilot → fan-out → storage → retire.**
  basestar goes first (smallest blast radius, already fragmented so
  any unified state is an improvement). Then pegasus and raider in
  parallel. Then storage (largest blast radius, 5 plans). Then the
  rustic module retirement in a final cleanup commit once every
  `constellation.backup.enable = true` call site is gone.

## Open Questions

### Resolved During Planning

- **raider inclusion:** Resolved during planning — raider is in
  Phase A. See origin doc Open Question #1.
- **basestar endpoint choice:** Tailscale
  (`rest:http://storage.bat-boa.ts.net:8000/`), not the public
  cloudflared endpoint. Consistent with pegasus and raider, lower
  latency, no cloudflared dependency. basestar today uses both; the
  public one was an artifact of the native-restic profile being
  added independently.
- **Notification noise budget:** Failures always; success only on
  first-after-failure. First-run validation uses a temporary extra
  hook with `CONDITION_SNAPSHOT_SUCCESS` that's removed after the
  cycle is verified.
- **Backrest scheduler vs systemd timers:** Backrest internal (see
  Key Technical Decisions).
- **nixpkgs has no `services.backrest`:** Confirmed. Wrapper module
  is the path forward.
- **Config file must be outside the Nix store:** Confirmed.
  `ExecStartPre` render + copy into `/var/lib/backrest/` is the
  idiom.

### Resolved During Planning (Post-Review)

The following were surfaced by ce-doc-review and settled with the
plan owner before Unit 1 begins.

- **Bind address + trust model:** Bind `0.0.0.0:9898`, firewall on
  `tailscale0` only. Trust model is stated explicitly: tailnet peers
  plus root-equivalent local processes are trusted to hit Backrest
  without Authelia. Authelia only gates the
  `backrest-<host>.arsfeld.one` public subdomain path. **Plan
  requirement:** a Tailscale ACL restricts `tcp:9898` to the
  operator's devices (enforced outside this repo, in the Tailscale
  admin console). Document the ACL as a prerequisite in
  `docs/architecture/backup.md` during Unit 5.
- **Service user:** root. Matches every existing backup service in
  this repo (`services.rustic`, `services.restic.backups` on
  storage, basestar). No sops secret-ACL changes needed. Systemd
  unit starts as root, reads `EnvironmentFile=` (including the
  0400-owner-arosenfeld `ntfy-publisher-env`), then executes
  Backrest. Forgoes `DynamicUser` hardening — acceptable because
  the daemon legitimately needs root to read `/var/lib`, `/home`,
  `/root`, and `/`.
- **Heartbeat for silent-never-ran detection:** Deferred. Phase A
  ships with failure-only ntfy. Operators confirm green state by
  opening the Backrest UI on demand. If a silent-never-ran incident
  actually happens, revisit and add a scheduled summary timer then
  — don't pre-build for a failure mode that hasn't surfaced.
- **Storage I/O class:** Accept best-effort on all five plans
  initially. Observe interactive impact during the first full cron
  window (Sunday morning). If regression is noticeable, escalate
  post-deploy by adding a per-plan `ioClass` option that makes
  `BACKREST_RESTIC_COMMAND` point at an ionice wrapper script.
  Captured as a monitoring task in Unit 4's verification.
- **Backrest package source:** Module default is
  `pkgs-unstable.backrest`, following the established repo pattern
  (`pkgs-unstable.immich`, `pkgs-unstable.nextcloud32`,
  `pkgs-unstable.zed-editor`). At the time of planning, both
  nixpkgs-stable and nixpkgs-unstable ship 1.10.1 — but the
  unstable channel cuts releases faster, so bumps arrive without
  waiting for the next stable. Feasibility reviewer verified
  `actionWebhook`, `CONDITION_*`, `auth.disabled`, and
  `backup_flags`-based `--exclude-if-present` are all present in
  1.10.1's proto — no fallback path needed unless a future
  schema-drift finding appears during Unit 1.

### Deferred to Implementation

- **Whether `oplog.sqlite` belongs in the host's own backup set.**
  Losing it means a full reindex from the repo on next startup —
  slow for storage's multi-TB repos. Currently covered incidentally
  via `/var/lib` being in system backup; measure reindex time on
  pegasus during Unit 3a and decide whether to explicitly include
  or exclude it on storage.
- **Cross-host gateway proxy resolution.** Whether bare short-name
  `basestar:9898` resolves from storage's Caddy over Tailscale
  MagicDNS, or whether we need to pass FQDN (`basestar.bat-boa.ts.net`)
  through the gateway submodule. First discovered in Unit 2 deploy;
  fix forward.
- **Per-host `TZ=` env for the scheduler.** Default to system TZ.
  Flag for revisit only if a cron time drifts unexpectedly.
- **Storage cron-time clustering (Sunday 02:30–07:30 local).** A
  bad Sunday morning wipes all remote-backup windows for the week.
  Alternative: spread weekly plans across different days. Defer
  until one real-world incident demonstrates the clustering matters
  or until a user flag during review.
- **Fate of existing `rest:https://restic.arsfeld.one/basestar`
  repo.** After Unit 2 collapses basestar's two profiles into one
  targeting storage, the public restic.arsfeld.one/basestar repo
  ages out with no new writes. Decide whether to explicitly delete
  it (reclaim space) or keep as a read-only historical archive.

## High-Level Technical Design

> *This illustrates the intended approach and is directional guidance
> for review, not implementation specification. The implementing agent
> should treat it as context, not code to reproduce.*

### Module data flow

```
┌────────────────────────────────────────────────────────────┐
│ host configuration.nix                                      │
│  constellation.backrest = {                                 │
│    enable = true;                                           │
│    instance = "basestar";        ← defaults to hostname    │
│    repos.storage = {                                        │
│      uri = "rest:http://storage.bat-boa.ts.net:8000/";     │
│      passwordFile = sops."restic-password".path;            │
│    };                                                       │
│    plans.system = {                                         │
│      repo = "storage";                                      │
│      paths = [ "/var/lib" "/home" "/root" ];                │
│      excludes = [ ... ];                                    │
│      schedule.cron = "30 3 * * *";                          │
│      retention = { daily = 7; weekly = 4; monthly = 6; };   │
│    };                                                       │
│    hooks.default = [ ntfy-failure ntfy-success-recovery ]; │
│  };                                                         │
└────────────────────────────────────────────────────────────┘
                            │
                            ▼
┌────────────────────────────────────────────────────────────┐
│ modules/constellation/backrest.nix                          │
│   • renders config.json.tmpl (with ${SECRET} placeholders) │
│     into /nix/store via pkgs.writeText                      │
│   • systemd unit: ExecStartPre=envsubst → /var/lib/backrest │
│   • EnvironmentFile=/run/secrets/... loads secrets          │
│   • ExecStart=${pkgs.backrest}/bin/backrest                 │
│   • env: BACKREST_DATA=/var/lib/backrest                    │
│          BACKREST_CONFIG=/var/lib/backrest/config.json      │
│          BACKREST_PORT=0.0.0.0:9898                         │
│          BACKREST_RESTIC_COMMAND=${pkgs.restic}/bin/restic  │
└────────────────────────────────────────────────────────────┘
                            │
                            ▼
┌────────────────────────────────────────────────────────────┐
│ Runtime: Backrest speaks to repo, runs plans on schedule,   │
│ fires hooks. On success/error, shoutrrr ntfy URL posts to   │
│ ntfy.arsfeld.one/backups with templated body. Caddy on      │
│ storage forward-auths backrest-<host>.arsfeld.one → host:9898│
└────────────────────────────────────────────────────────────┘
```

### Per-host rollout order

```mermaid
graph LR
  U1[Unit 1: Module] --> U2[Unit 2: Pilot basestar]
  U2 --> U3a[Unit 3a: pegasus]
  U2 --> U3b[Unit 3b: raider]
  U3a --> U4[Unit 4: storage]
  U3b --> U4
  U4 --> U5[Unit 5: Retire rustic + docs]
```

Unit 2 gates 3a/3b only in the sense that the first cycle on basestar
should complete and notify before we fan out — it validates the module
itself. 3a and 3b can run in parallel PRs. Unit 4 should wait until 3a
is confirmed because pegasus is also a backup *destination* for
storage; migrating it first lets us verify the storage→pegasus write
path still works with Backrest in the middle.

## Implementation Units

- [ ] **Unit 1: Backrest constellation module**

**Goal:** Introduce `constellation.backrest` as a thin Nix wrapper
around the `backrest` package. Render a runtime-mutable `config.json`
from a small declarative option surface. No host uses it yet.

**Requirements:** foundation for R1, R2, R3, R4, R6.

**Dependencies:** none.

**Files:**
- Create: `modules/constellation/backrest.nix`
- Create: `modules/constellation/backrest-hooks.nix` (optional — may
  live inside the main module if small)
- Test: build-time validation via `nix flake check` plus a minimal
  smoke host defined in `flake-modules/checks.nix` if the existing
  checks machinery supports it. If not, validate by building the
  first consumer host (basestar) in Unit 2.

**Approach:**
- Option surface (keep narrow):
  - `enable` (bool)
  - `instance` (str, default `config.networking.hostName`)
  - `package` (derivation, default `pkgs-unstable.backrest`)
  - `bindAddress` (str, default `"0.0.0.0:9898"`)
  - `openFirewall` (bool, default true — opens 9898 on tailscale0)
  - `repos` (attrsOf submodule: `uri`, `passwordFile`, `env`,
    `envFile`, `flags`, `autoUnlock`)
  - `plans` (attrsOf submodule: `repo`, `paths`, `excludes`,
    `excludeIfPresent` (list of filename markers — rendered into
    `backup_flags` as `--exclude-if-present=FILE` entries because
    Backrest's proto `Plan` has no dedicated field for this),
    `schedule` (oneof cron/intervalHours/intervalDays,
    `clock = "local"|"utc"|"last-run"`), `retention` (attrs of
    hourly/daily/weekly/monthly/yearly), `extraBackupFlags` (list),
    `hooks` (list of hook submodules, optional — a module-level
    default failure-hook applies when this is empty))
- **Default failure hook** (module-level, always applied to every
  plan unless explicitly disabled): a single `actionWebhook` entry
  POSTing to `https://ntfy.arsfeld.one/backups` with an
  `Authorization: Basic ${NTFY_BASIC_AUTH_B64}` header. Conditions:
  `CONDITION_ANY_ERROR`, `CONDITION_SNAPSHOT_ERROR`. Body is a
  Go-template: `{{.Event}} on {{.Repo.Id}}/{{.Plan.Id}} (host {{.Config.Instance}}): {{.Error}}`.
- Render `config.json` as follows:
  1. Nix builds a pure-JSON template at `/nix/store/...-backrest-config.json.tmpl`
     with `${VAR}` placeholders for secrets.
  2. Systemd unit `ExecStartPre` script:
     - Ensure `/var/lib/backrest` exists, mode 0700, owner backrest.
     - `envsubst < ${configTmpl} > /var/lib/backrest/config.json.new`
     - `mv` atomically onto `config.json`.
  3. `EnvironmentFile=` loads: `restic-password`, `ntfy-publisher-env`,
     plus any repo-specific envFile (hetzner-webdav-env).
- Systemd unit:
  - `Type=simple`, runs as **root** (matches every other backup
    service in this repo; see "Service user" in Resolved During
    Planning).
  - Env: `BACKREST_DATA=/var/lib/backrest`,
    `BACKREST_CONFIG=/var/lib/backrest/config.json`,
    `BACKREST_PORT=${bindAddress}`,
    `BACKREST_RESTIC_COMMAND=${pkgs.restic}/bin/restic` —
    hardcoded to the nixpkgs restic so Backrest does not
    auto-download its own binary into the data directory,
    `XDG_CACHE_HOME=/var/cache/backrest`.
  - Path adds `pkgs.rclone` for rclone-based repos (hetzner),
    `pkgs.openssh` for SFTP if ever used.
  - `ReadWritePaths` includes any local-disk repo path (e.g.
    `/mnt/storage/backups/restic` on storage).
  - Hardening: `PrivateTmp`, `ProtectSystem=strict`,
    `ProtectHome=read-only` (Backrest needs to READ `/home` for some
    plans — confirm with real run, but default to read-only).
  - `IOSchedulingClass=best-effort` (storage's nas profile may need
    idle — per-plan override via systemd drop-in if needed).
- Firewall: when `openFirewall`, append 9898 to
  `networking.firewall.interfaces.tailscale0.allowedTCPPorts`.
- The module-level default failure hook described in Key Technical
  Decisions is auto-injected into every plan unless the plan
  explicitly disables it via an empty `hooks = []` override. No
  success or recovery hooks in Phase A.
- NO migration or host-level changes in this unit. Module lands in
  isolation and is inert.

**Patterns to follow:**
- Option surface and systemd wiring: mirror `modules/rustic.nix`
  attribute-for-attribute where the semantics overlap.
- Secret loading: mirror the existing sops `EnvironmentFile=` pattern
  used in `hosts/storage/backup/backup-restic.nix` for `hetzner-webdav-env`.
- Directory hardening: mirror `services.restic.server` pattern on
  `hosts/pegasus/backup/backup-server.nix` (StateDirectory,
  RequiresMountsFor, ReadWritePaths).

**Test scenarios:**
- *Happy path:* Module with a single repo + plan evaluates cleanly on
  `nix build .#nixosConfigurations.<any>.config.system.build.toplevel`.
- *Happy path:* Generated `config.json.tmpl` parses as valid JSON.
  Because Backrest ships no `--check-config` subcommand (the binary
  is daemon-only), schema validation happens by running the daemon
  pointed at a throwaway data dir: `BACKREST_DATA=$(mktemp -d)
  BACKREST_CONFIG=/tmp/test-config.json ${pkgs.backrest}/bin/backrest`
  — if Backrest parses the config successfully, the UI becomes
  reachable at `:9898`.
- *Edge case:* `plans.<name>.schedule.cron = "bad cron"` produces a
  module evaluation error with a clear message, not a silent runtime
  crash.
- *Edge case:* `plans.<name>.repo = "<missing>"` produces a module
  evaluation error listing the defined repos.
- *Edge case:* `plans.<name>.excludes` with a list of paths containing
  shell-metacharacters gets JSON-encoded correctly (no shell
  injection into the rendered template).
- *Error path:* Secret env var referenced but not present in
  `EnvironmentFile` causes the `envsubst -no-unset -no-empty` step
  to exit non-zero, which fails the ExecStartPre and holds the
  service in `failed` state rather than starting Backrest with a
  broken config. Test by deliberately unsetting one env var from
  the EnvironmentFile and asserting the unit enters `failed`.
- *Integration:* Starting the service with a config pointing at a
  restic repo on localhost (e.g. `/tmp/test-repo`) initializes and
  completes one backup cycle when triggered via the Backrest web UI
  or `grpcurl` against the `Backup` gRPC method (the binary offers
  no CLI subcommand for ad-hoc runs). Pilot host (Unit 2) is where
  this gets validated end-to-end against a real remote repo.

**Verification:**
- `nix build .#nixosConfigurations.storage.config.system.build.toplevel`
  succeeds with the module imported but no hosts enabling it.
- The constellation module is auto-loaded (per haumea convention) and
  `config.constellation.backrest.enable` option is available on every
  host.
- A dev-shell evaluation of a minimal config produces a well-formed
  JSON template matching the Backrest proto field names observed in
  the research (`modno`, `version`, `instance`, `repos`, `plans`,
  `auth.disabled`).

---

- [ ] **Unit 2: Pilot migration — basestar**

**Goal:** Migrate basestar as the first consumer. Collapse the
`constellation.backup.enable` rustic profile (weekly, to
`storage.bat-boa.ts.net:8000`) and the native
`services.restic.backups.basestar` profile (daily, to
`restic.arsfeld.one/basestar`) into **one** Backrest plan writing to
`storage.bat-boa.ts.net:8000` daily.

**Requirements:** R2, R3, R4, R6 for basestar.

**Dependencies:** Unit 1.

**Files:**
- Modify: `hosts/basestar/configuration.nix` — remove
  `constellation.backup.enable = true;` line.
- Replace: `hosts/basestar/backup.nix` — old `services.restic.backups.basestar`
  block replaced with `constellation.backrest = { ... };` invocation.
  Keep the file path and import stable.
- Modify: `hosts/storage/services/` — add a new file (e.g.
  `hosts/storage/services/backrest-portal.nix`) that registers
  `media.gateway.services.backrest-basestar` with `host = "basestar"`
  and `port = 9898`. Add to the storage services `default.nix` imports.
- Test: manual validation on the deployed host, plus a flake check via
  `nix build .#nixosConfigurations.basestar.config.system.build.toplevel`.

**Approach:**
- Plan shape on basestar:
  - `repos.storage = { uri = "rest:http://storage.bat-boa.ts.net:8000/"; passwordFile = ...; }`
  - `plans.system = { repo = "storage"; paths = [ "/var/lib" "/home" "/root" ]; excludes = [ "/var/lib/docker" "/var/lib/containers" "/var/lib/systemd" "/var/lib/libvirt" "**/.cache" "**/.nix-profile" ]; schedule.cron = "30 3 * * *"; retention = { daily = 7; weekly = 4; monthly = 6; }; hooks = [ "ntfy-failure" "ntfy-success-first-run" ]; }`
  - The path set is the **superset** of today's two profiles:
    rustic covered `/var/lib /home /root`, native-restic covered
    `/var/lib /root`. Superset is rustic's.
  - Excludes are the union of today's two exclusion sets.
- The rustic module's behavior to replicate for parity:
  `!/var/lib/docker`, `!/var/lib/containers`, `!/var/lib/systemd`,
  `!/var/lib/libvirt`, `!/var/lib/lxcfs`, `!/var/cache`, `!/nix`,
  `!/mnt`, `!**/.cache`, `!**/.nix-profile`, plus
  `excludeIfPresent = [".nobackup" "CACHEDIR.TAG"]` (the new
  module's dedicated option; renders to `--exclude-if-present`
  entries in `backup_flags` since Backrest's proto `Plan` has no
  direct field).
- Gateway registration lives on **storage** (the host running Caddy
  for `*.arsfeld.one`), not on basestar. Entry: `backrest-basestar`
  with `host = "basestar"`, `port = 9898`, default `bypassAuth = false`
  (Authelia enforced).
- basestar's Backrest binds to `0.0.0.0:9898`; firewall opens 9898
  on `tailscale0`. Reachable from storage's Caddy over Tailscale.
- Validation protocol (executed by operator after deploy):
  1. Deploy basestar. Confirm `systemctl status backrest` is active.
  2. Confirm `backrest-basestar.arsfeld.one` loads and Authelia
     challenges.
  3. In the UI, manually trigger the `system` plan. Confirm
     completion and a new snapshot visible against the existing
     basestar `--host` tag on the storage repo.
  4. Force a failure: temporarily set an invalid repo URL or pause
     storage's restic server, trigger the plan, confirm the ntfy
     failure hook posts to `ntfy.arsfeld.one/backups`.
  5. Let one scheduled cycle run overnight; confirm it completes.
- After validation, disable the old profiles: the rustic push
  stops when `constellation.backup.enable` is unset; the native-restic
  push stops when the `services.restic.backups.basestar` block is
  removed from `hosts/basestar/backup.nix`.
- **Do not delete `modules/rustic.nix` yet.** pegasus and raider still
  reference it until Units 3a/3b land.

**Execution note:** Deploy with `just test basestar` first (ephemeral
activation) to catch any runtime issues without overwriting the
bootloader entry. Only `just deploy basestar` after the service starts
cleanly under test.

**Patterns to follow:**
- **Cross-host gateway proxy is a new pattern.** The repo has no
  existing `media.gateway.services.<name> { host = "<other-host>"; }`
  call site — every current entry runs on its own host. The
  `media/__utils.nix` proxy generator currently emits
  `reverse_proxy <host>:<port>` (bare name). Storage's Caddy reaches
  other hosts via Tailscale MagicDNS; resolution of the bare
  hostname from the caddy systemd context is **unverified**. Unit 2
  must confirm on first deploy, and if short-name resolution fails,
  either (a) add a `proxyHost` option to the gateway submodule that
  accepts an FQDN, or (b) extend `__utils.nix` to append
  `.bat-boa.ts.net` when the service's host differs from the
  current host. Pick the simpler of the two once empirical behavior
  is known.
- sops secret loading: existing basestar pattern for
  `restic-password` and `restic-rest-cloud`. The new module needs
  `restic-password`. The `restic-rest-cloud` secret (used by today's
  native-restic push to `restic.arsfeld.one/basestar`) becomes
  unused after this unit — remove from `hosts/basestar/backup.nix`
  and from `secrets/sops/basestar.yaml` in this unit's commit. See
  Open Questions for the fate of existing snapshots on
  `rest:https://restic.arsfeld.one/basestar`.

**Test scenarios:**
- *Happy path:* After deploy, `journalctl -u backrest` shows the
  service started, config loaded, and at least one scheduled run
  completed on schedule without error.
- *Happy path:* `restic -r rest:http://storage.bat-boa.ts.net:8000/ snapshots --host basestar` (run from storage, against storage's
  REST server) shows a new snapshot dated post-deploy with the
  expected path set.
- *Edge case:* basestar offline during the scheduled window →
  Backrest logs a skipped run; next successful run reconciles. No
  ntfy spam on planned-offline states.
- *Error path:* Repo unreachable (stop storage's restic-rest-server
  briefly) → failing run fires the ntfy-failure hook within the
  configured retry window. Message includes hostname (`basestar`)
  and plan id (`system`) via the shoutrrr template.
- *Error path:* Invalid repo password → plan run fails with clear
  Backrest UI error; ntfy-failure fires.
- *Integration:* The `basestar` snapshot appears under the same
  `--host` tag on storage's repo that the old rustic profile used
  — verified by walking the snapshot list and confirming no orphan
  host tag from the migration.

**Verification:**
- `constellation.backup.enable` is no longer set on basestar.
- `services.restic.backups.basestar` is no longer defined.
- `backrest-basestar.arsfeld.one` is reachable through Authelia.
- ntfy topic `backups` received at least one failure notification
  (forced) and one success notification (first-run) identifiable as
  coming from `basestar`.
- One full overnight scheduled cycle has completed successfully.

---

- [ ] **Unit 3a: pegasus migration**

**Goal:** Replace pegasus's `constellation.backup.enable = true` with a
Backrest plan writing to `rest:http://storage.bat-boa.ts.net:8000/`,
preserving the weekly cadence.

**Requirements:** R2, R3, R4 for pegasus.

**Dependencies:** Unit 2 (validated).

**Files:**
- Modify: `hosts/pegasus/configuration.nix` — remove
  `backup.enable = true;` from the `constellation = { ... };` attrset.
  Add `constellation.backrest.enable = true` (inline or via a new
  `hosts/pegasus/backup/backup-client.nix`).
- Create: `hosts/pegasus/backup/backup-client.nix` (peer of the existing
  `backup-server.nix` for clarity — pegasus is both a server and a
  client now).
- Modify: `hosts/pegasus/backup/default.nix` — add the new import.
- Modify: `hosts/storage/services/backrest-portal.nix` (from Unit 2) —
  add the `backrest-pegasus` entry.

**Approach:**
- Plan shape mirrors basestar but with a **weekly** schedule
  (`schedule.cron = "30 3 * * 0"`) to match the rustic module's
  current `OnCalendar = "weekly"`.
- Paths: `/var/lib /home /root` (same as rustic's current sources).
- Excludes: match the rustic module's globs exactly
  (`!/var/lib/docker`, `!/var/lib/containers`, etc.) plus
  `!/mnt/storage/backups/restic-server` (so pegasus doesn't recursively
  back up the repo it *serves*).
- Note: pegasus also runs `services.restic.server` (see
  `hosts/pegasus/backup/backup-server.nix`) — unaffected by this plan
  (see Unchanged Invariants).

**Execution note:** Same `just test pegasus` → `just deploy pegasus`
dance as basestar.

**Patterns to follow:**
- Same as Unit 2.

**Test scenarios:**
- *Happy path:* After deploy, Backrest runs its first scheduled
  weekly cycle and creates a snapshot on the storage repo with
  `--host pegasus`.
- *Edge case:* pegasus reboots mid-run → Backrest resumes on next
  schedule; no partial-snapshot corruption (restic's native
  atomicity handles this).
- *Edge case:* The `!/mnt/storage/backups/restic-server` exclusion
  actually excludes the repo-being-served — verified by inspecting
  the snapshot's file list; confirm nothing under that path is
  present.
- *Error path:* storage's REST server down → ntfy-failure fires.
- *Integration:* pegasus is simultaneously a Backrest **client**
  (this plan) and a restic **server** (`backup-server.nix`). Both
  must start cleanly; neither's systemd unit blocks the other.
  Verify `systemctl list-units` shows both active.

**Verification:**
- `constellation.backup.enable` removed from pegasus.
- New Backrest plan visible at `backrest-pegasus.arsfeld.one`.
- First weekly cycle completed; ntfy received the first-run success
  notification.

---

- [ ] **Unit 3b: raider migration**

**Goal:** Replace raider's `constellation.backup.enable = true` with a
Backrest plan writing to `rest:http://storage.bat-boa.ts.net:8000/`.
Use an **interval-based** schedule (`CLOCK_LAST_RUN_TIME`) instead of a
cron since raider is a laptop and may be suspended when cron would
fire.

**Requirements:** R2, R3, R4 for raider.

**Dependencies:** Unit 2 (validated). Independent of Unit 3a.

**Files:**
- Modify: `hosts/raider/configuration.nix` — remove
  `backup.enable = true;` from `constellation = { ... };`, add
  `constellation.backrest = { ... }` block (likely inline given how
  the file is structured; move to a `hosts/raider/backup.nix` if
  the block exceeds ~30 lines).
- Modify: `hosts/storage/services/backrest-portal.nix` — add
  `backrest-raider` entry.
- **No secret-file work on raider.** `ntfy-publisher-env` is already
  declared on raider at `hosts/raider/configuration.nix:34-38`
  pointing at the shared `secrets/sops/ntfy-client.yaml`. The
  remaining concern is whether the Backrest service user (see
  "Secret owner reconciliation" in Key Technical Decisions) can
  read it — resolved globally in Unit 1, not per-host here.

**Approach:**
- Plan shape:
  - Schedule: `schedule.maxFrequencyHours = 24` with `clock = "last-run"`.
    Means "run 24 hours after the previous successful run"; skips if
    last run was < 24h ago, catches up after long suspensions.
  - Paths: same as rustic's sources (`/var/lib /home /root`).
  - Excludes: same rustic exclusion set + raider-specific additions:
    `**/.cache`, `**/node_modules`, `/home/*/.local/share/Steam`,
    `/home/*/Downloads` (TBD — confirm during implementation by
    inspecting `hosts/raider/` for relevant state paths). Start with
    the rustic set unchanged; add raider-specific ones only if the
    first run is huge.
- ntfy hook: same as basestar.
- raider's UI exposed at `backrest-raider.arsfeld.one` — same
  Authelia gate. Firewall opens 9898 on tailscale0.

**Execution note:** Desktop workstation — user is present to observe.
`just test raider` first, watch `journalctl -u backrest -f` during
service start, then `just deploy raider` once the first run completes
cleanly.

**Patterns to follow:**
- Secret is already declared — no pattern to introduce on raider.

**Test scenarios:**
- *Happy path:* Interval scheduler produces a run within
  `maxFrequencyHours + slack` after first boot.
- *Edge case:* Machine suspended for 72h; on resume, Backrest detects
  the last-run interval is exceeded and runs once — not three times.
  **Pre-verify before Unit 3b deploys:** read
  `backrest/internal/orchestrator/taskrunner.go` in nixpkgs's
  backrest source (at the pinned version) to confirm the
  catch-up-only-once semantics; do not rely on the name
  `LAST_RUN_TIME` as a behavior guarantee.
- *Edge case:* Network offline → Backrest retries per its policy;
  ntfy-failure fires only if the retry window is exhausted.
  **Pre-verify:** confirm whether retries during network flaps
  produce individual ntfy-failure posts or are aggregated into one;
  raider on flaky wifi could otherwise spam the topic.
- *Error path:* Active user workload during backup → I/O scheduling
  at best-effort priority 7 does not visibly impact foreground
  responsiveness. (Subjective; observable.)
- *Integration:* The `raider` snapshot on the shared storage repo
  is tagged with `--host raider`, distinguishable from basestar/
  pegasus tags.

**Verification:**
- `constellation.backup.enable` removed from raider.
- `secrets/sops/raider.yaml` has `ntfy-publisher-env`.
- `backrest-raider.arsfeld.one` loads behind Authelia from another
  trusted machine.
- At least one successful scheduled run; ntfy saw the first-run
  notification.

---

- [ ] **Unit 4: storage migration**

**Goal:** Migrate storage's five hand-rolled `services.restic.backups`
profiles (`nas`, `hetzner-system`, `hetzner`, `pegasus-system`,
`pegasus`) to five Backrest plans, preserving every repository, path,
exclusion, schedule, and retention policy verbatim.

**Requirements:** R2, R3, R4, R5 for storage (biggest blast radius).

**Dependencies:** Units 2 and 3a. **Note:** Unit 3a migrates
pegasus's *client* side only (its own push to storage). Pegasus's
REST *server* (receiving storage's `pegasus-system` and `pegasus`
plans) is an Unchanged Invariant, so there is no "Backrest in the
middle" on that write path. The dependency on Unit 3a is therefore
about **validation ordering** (roll out incrementally by blast
radius; have two small migrated hosts producing green signal before
touching the largest one), not about correctness of the pegasus
destination. In principle 3a and 4 could land in parallel; ordering
is chosen for risk management.

**Files:**
- Delete: `hosts/storage/backup/backup-restic.nix` (5 profile
  definitions).
- Create: `hosts/storage/backup/backrest-client.nix` — storage's
  `constellation.backrest = { ... };` block with 5 plans.
- Modify: `hosts/storage/backup/default.nix` — remove the
  `./backup-restic.nix` import, add `./backrest-client.nix`.
- Modify: `hosts/storage/services/backrest-portal.nix` — add
  `backrest-storage` entry. Same-host proxy (`host = "storage"`,
  `port = 9898`).
- Modify: `docs/architecture/backup.md` — update Rustic/Restic
  sections to reflect Backrest (in Unit 5, but flag here because
  storage's section is the biggest).

**Approach:**
- Re-express each current restic profile as a Backrest plan. Mapping:

| Current restic profile | Backrest plan | Repo uri | Schedule | Retention |
|---|---|---|---|---|
| `nas` | `nas` | `/mnt/storage/backups/restic` (local) | `cron 30 2 * * *` (daily) | daily=7, weekly=5, monthly=12 |
| `hetzner-system` | `hetzner-system` | `rclone:hetzner:backups/restic-system` | `cron 30 4 * * 0` (weekly) | daily=7, weekly=4, monthly=6 |
| `hetzner` | `hetzner` | `rclone:hetzner:backups/restic` | `cron 30 5 * * 0` (weekly) | same |
| `pegasus-system` | `pegasus-system` | `rest:http://pegasus.bat-boa.ts.net:8000/` | `cron 30 6 * * 0` (weekly) | same |
| `pegasus` | `pegasus` | same | `cron 30 7 * * 0` (weekly) | same |

  (Exact cron times are new — the current rustic module uses
  `OnCalendar = "weekly"` + `RandomizedDelaySec`. Backrest doesn't
  support systemd-style random delay natively; pick fixed times
  spaced far enough apart to avoid stampedes on storage's NAS.
  Acceptable because retention math is monthly-granular.)

- Five plans share the two exclude lists from the existing file:
  `systemExcludes` and `userExcludes`. Inline them into the
  backrest-client.nix file.
- Paths:
  - `nas`, `*-system`: `paths = [ "/" ]` with systemExcludes.
  - `hetzner`, `pegasus`: `paths = [ "/home" "/mnt/storage" ]` with
    userExcludes.
- Per-plan I/O scheduling overrides for the units that currently run
  as idle-class (`restic-backups-nas`, `restic-backups-hetzner-system`,
  `restic-backups-pegasus-system`) — Backrest's own scheduler doesn't
  support per-plan I/O class. Option A: keep all plans at
  best-effort and rely on them being spaced out. Option B: wrap
  Backrest with `systemd-run` or a pre-exec `ionice` for specific
  plans. **Resolve at implementation time** based on measured NAS
  impact on the first full cycle. (Added to Open Questions.)
- `environmentFile` for rclone-based repos: same
  `hetzner-webdav-env` secret used today.
- `TimeoutStartSec = "infinity"` override on the systemd unit (see
  current rustic-wrapper's pattern via `systemd.services.*.serviceConfig`).
  In Backrest's case there's only ONE systemd unit (the Backrest
  daemon itself), not per-plan. The infinite-start concern doesn't
  apply the same way — plans run inside the daemon, not as separate
  units. First-seed time concerns are moot; the relevant timeout is
  restic's own operation timeout, which is unbounded by default.

**Execution note:** This is the highest-stakes host. Deploy order:
1. Build on storage: `nix build .#nixosConfigurations.storage.config.system.build.toplevel`.
2. `just test storage` (ephemeral) — confirm Backrest starts, loads
   the 5-plan config, and the UI is reachable.
3. **Measure first-connect cost on each remote repo.** Backrest
   imports existing restic repos by running `restic snapshots` and
   indexing the result into its SQLite oplog. On storage's
   multi-year hetzner repos this may take non-trivial time; before
   committing, log how long each repo takes to appear in the UI
   after Backrest starts. If any repo exceeds ~30 minutes, stop and
   reassess (option: `BACKREST_DATA` on fast SSD, or accept a
   slower first boot).
4. In UI, **trigger `nas` manually** (local disk, no remote risk).
   Confirm snapshot appears in `/mnt/storage/backups/restic`.
5. Trigger each remote plan manually in sequence. Watch
   `journalctl -u backrest` and restic output in Backrest's
   processlogs for the first run.
6. **Pause all schedules before `just deploy storage`.** The
   Backrest UI allows disabling individual plan schedules. Disable
   all five on the `just test storage` ephemeral run, trigger
   backups manually, and only re-enable schedules after one
   complete manual cycle is confirmed on every plan. This prevents
   a first-prune run with new retention semantics from deleting
   snapshots before manual verification.
7. Only after all 5 plans succeed manually with schedules re-enabled,
   `just deploy storage` to activate persistently.

**Patterns to follow:**
- Local-disk repo: the existing `nas` profile's use of a local path
  — verify Backrest accepts bare filesystem paths as `repo.uri`.
- rclone-based repo env wiring: current
  `hosts/storage/backup/backup-restic.nix:169` pattern.

**Test scenarios:**
- *Happy path:* All 5 plans execute one cycle manually without error.
- *Happy path:* `restic -r <repo> snapshots --host storage` on each
  of the 5 repos shows a new snapshot created by Backrest's run,
  with the same path set and similar dedup ratio as the previous
  rustic run (within 5%).
- *Edge case:* The `nas` plan targets `/mnt/storage/backups/restic`
  while the same mount contains `/mnt/storage/backups/restic-server`
  (storage's own REST server data). Confirm the exclusion `!/mnt`
  in `systemExcludes` prevents recursive self-backup. (Historical
  restic profile had this; must not regress.)
- *Edge case:* Hetzner upstream slow → first run takes multiple
  hours. Backrest daemon stays up; UI shows progress; no timeout.
- *Error path:* rclone credentials missing → Backrest's first
  operation logs a clear error, ntfy-failure fires.
- *Error path:* Pegasus REST server not yet migrated (Unit 3a not
  deployed) → storage's pegasus plans fail with network error. This
  should NOT happen if Unit 3a landed first; the dependency exists
  to prevent it.
- *Integration:* Each plan's snapshot is attributable to
  `--host storage`. Retention prunes on schedule produce the
  expected keep-N counts. Verify by inspecting snapshot counts one
  month post-deploy.

**Verification:**
- Old `hosts/storage/backup/backup-restic.nix` deleted.
- `backrest-storage.arsfeld.one` loads and shows 5 plans.
- Each of the 5 existing restic repos has a fresh Backrest-authored
  snapshot within its scheduled window.
- `services.restic.server` on storage is still running (unchanged
  invariant — see below).
- ntfy topic `backups` shows expected notifications per plan.

---

- [ ] **Unit 5: Retire rustic module + refresh docs**

**Goal:** Delete the rustic wrapper module and the old
`constellation.backup` module now that no host uses them. Update the
backup architecture doc.

**Requirements:** R1, R5.

**Dependencies:** Units 2, 3a, 3b, 4 all landed and validated (at
least one successful scheduled cycle on each host, plus at least
one ntfy-failure confirmed per host).

**Files:**
- Delete: `modules/rustic.nix`
- Delete: `modules/constellation/backup.nix`
- Modify: `docs/architecture/backup.md` — rewrite the "Backup
  Configuration", "Rustic Module", and "Monitoring" sections to
  describe Backrest. Update the mermaid graph nodes from "Rustic
  Client" to "Backrest".
- Modify: `docs/guides/disaster-recovery.md` — update any `rustic`
  CLI references (if any) to `restic` + Backrest UI paths.
- Modify: `README.md` / `CLAUDE.md` — scan for stale rustic mentions;
  update only the architecture-describing passages, not historical
  ones.

**Approach:**
- This is a pure deletion + documentation unit. No logic change.
  A `grep -rni 'constellation\.backup' .` and
  `grep -rni 'services\.rustic' .` should come back clean (modulo
  archived plan/brainstorm docs in `docs/brainstorms/` and
  `docs/plans/`, which represent historical state and stay).
- Run `just build <host>` for all four migrated hosts as a
  build-time sanity check that no stale reference to the deleted
  modules remains.

**Patterns to follow:**
- Module deletion precedent: the cleanup commit of any prior plan
  that removed a module — e.g. the murder-script-safety or
  tsnsrv→tailscale-services migrations.

**Test scenarios:**
- *Happy path:* `nix flake check` passes after deletion.
- *Happy path:* Each of the four host configurations builds to
  a toplevel derivation cleanly.
- *Edge case:* A host file that imported `modules/rustic.nix` by
  path (bypassing haumea auto-discovery) would fail to build.
  Discover such imports with `grep -r 'rustic\.nix'` before
  deletion; fix any hits.
- Test expectation: no behavioral assertions — this is a
  deletion/docs unit. Verification is build-clean.

**Verification:**
- The two files are gone.
- `grep -rn 'constellation\.backup' . | grep -v docs/` returns
  nothing.
- `grep -rn 'services\.rustic' . | grep -v docs/` returns
  nothing.
- `docs/architecture/backup.md` reads correctly end to end.
- All four host configurations build.

## System-Wide Impact

- **Interaction graph:** Backrest runs per host; each instance is
  independent. Storage's Caddy gateway proxies 4 new subdomains over
  Tailscale to port 9898 on each host. sops secrets
  (`restic-password`, `hetzner-webdav-env`, `ntfy-publisher-env`)
  get a new consumer (the Backrest systemd unit) on each migrated
  host. No existing service's interaction graph changes.
- **Error propagation:** Backup failures, previously silent except
  for systemd unit status + `OnFailure=` email hooks, now surface as
  ntfy posts on the `backups` topic. Email fallback retained via a
  systemd drop-in for `backrest.service` (`OnFailure=email-@.service`
  if such a pattern exists — verify during Unit 1; otherwise document
  that ntfy is the only notification path and accept the dependency
  on ntfy being up).
- **State lifecycle risks:**
  - `/var/lib/backrest/oplog.sqlite` is daemon state. Losing it
    forces a reindex on next startup — slow but not data-losing.
    Included in the host's system backup via existing `/var/lib`
    coverage.
  - `/var/lib/backrest/config.json` is daemon state written by the
    module's `ExecStartPre`. Reproducible from Nix; no backup
    concern.
  - Restic repo locks: Backrest's `autoUnlock: false` default means
    an abandoned lock (e.g. from a killed run) requires manual
    intervention. Consider setting `autoUnlock: true` on plans that
    target exclusively-ours repos (storage's nas, any repo where
    only one writer exists). Do NOT set it on shared repos
    (storage's rest server, pegasus's rest server) where multiple
    hosts write — could cover for a concurrency bug.
- **API surface parity:** None — Backrest exposes a web UI only; no
  internal API is consumed by other services today.
- **Integration coverage:** The one non-obvious multi-layer
  integration is raider's `ntfy-publisher-env` secret addition —
  secrets must land in the host's sops file AND be registered via
  `sops.secrets."ntfy-publisher-env"` AND match the module's
  `EnvironmentFile` reference. Tested in Unit 3b.
- **Unchanged invariants:**
  - `services.restic.server` on storage (`:8000`, `--no-auth`) is
    untouched. Continues serving as a write target for basestar,
    pegasus, raider pushes.
  - `services.restic.server` on pegasus is untouched. Continues
    serving storage's two pegasus-* plans.
  - sops file layout, age keys, and secret naming scheme unchanged.
  - Authelia configuration unchanged — new Caddy vhosts use the
    existing forward-auth pattern.
  - `constellation.media.gateway.services` option surface unchanged;
    this plan only adds new entries.
  - Existing restic snapshot history preserved 1:1 in every repo.

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| Backrest's `config.json` mutation model fights our Nix-rendered template, causing lost state after deploys | Disable Backrest's own auth (`auth.disabled: true`) — removes the main user-created state. `ExecStartPre` overwrites the file each start. SQLite oplog is regenerable. UI-edited retention/prune policies are also lost on deploy — document the UI as read-only. |
| `envsubst` silently substitutes empty strings for missing secrets | Use `envsubst -no-unset -no-empty` (flags present in `pkgs.gettext`). `set -u` in bash does NOT propagate into envsubst's substitution; the flags are the correct mechanism. Test in Unit 1 by deliberately dropping a variable from EnvironmentFile and asserting service-start failure. |
| Bind address + `auth.disabled` combination weakens the "Authelia is the gate" premise for local processes and direct tailnet peers | See "Bind address + trust model" in Open Questions. Must be resolved before Unit 1 ships. |
| Ntfy publisher credential appears in Backrest UI/processlogs if embedded in a shoutrrr URL | Use `actionWebhook` with `Authorization: Basic ${NTFY_BASIC_AUTH_B64}` header instead of shoutrrr. Keeps the credential in the EnvironmentFile, never in the rendered hook URL. |
| Rendered `config.json` contains cleartext repo password; `/var/lib/backrest/config.json` is itself included in `/var/lib` system backup | Acceptable: the password only unlocks the repo it was backed up into, not new material. Document explicitly; do not rotate the restic password without understanding that historical snapshots will still contain the old one. |
| Multi-writer shared password: compromise of any one backup client (storage, basestar, pegasus, raider) exposes/destroys all hosts' snapshots on the shared repo | Accepted risk, documented. Pre-existing condition (same `restic-password` in `common.yaml`). A destructive `restic forget --prune` from a compromised host is recoverable only from the parallel copies (hetzner, pegasus REST, local nas). The three-copy topology is the mitigation. |
| Shared repo lock contention across multiple Backrest instances | restic handles concurrency; `autoUnlock: false` on shared-repo plans. Accept occasional lock waits. |
| raider's Tailscale interface down when Caddy tries to proxy → 502 on the UI | Accept. UI availability follows host availability. Notifications still work when raider wakes. |
| storage's `nas` plan writing to `/mnt/storage/backups/restic` on the same mount as `services.restic.server`'s dataDir at `/mnt/storage/backups/restic-server` — risk of recursive self-backup | `!/mnt/storage/backups` exclusion in userExcludes prevents recursion. Confirm during Unit 4 verification by inspecting first snapshot's file list. |
| nixpkgs `backrest` 1.10.1 schema drift vs researched 1.12.x | See "nixpkgs 1.10.1 vs researched 1.12.x" in Open Questions. Pre-commit to a fallback before Unit 1 starts. |
| Unit 4's first scheduled prune-cycle is a point of no return | Unit 4 execution note requires pausing all plan schedules on the ephemeral (`just test`) deploy, manual-triggering all 5, and only re-enabling schedules after the first cycle is verified. Prevents Backrest's retention semantics from pruning snapshots the old rustic policy would have kept. |
| Migration on storage briefly leaves no scheduled backup | Unit 4 execution note requires manual trigger of all 5 plans via the UI before schedules are re-enabled and before the old profiles are removed. No window of no-backup by design. |
| Storage I/O class regression (3 of 5 plans are idle-class today; Backrest can't per-plan set I/O) | See "Storage I/O class" in Open Questions. Pre-commit to (a) accept, or (b) wrap restic calls via `BACKREST_RESTIC_COMMAND` pointing at a per-plan ionice wrapper. |
| ntfy + Authelia both co-located on storage; incident on storage blinds all observability | Accepted for Phase A. If recurrence becomes an issue, escalate to Open Questions item "Heartbeat / observability completeness" and add an external dead-man's-switch. |
| Backrest's first-connect oplog index on storage's multi-TB hetzner repos is slow | Measured during Unit 4 execution step 3; if any repo exceeds 30min, reassess before committing. |
| Cross-host gateway proxy is a new pattern (no existing FQDN-aware examples in the repo) | Verify short-name resolution works in Unit 2 deploy; fix forward by extending gateway utils if it doesn't. |

## Documentation / Operational Notes

- Update `docs/architecture/backup.md` as part of Unit 5.
- Add a brief "how to trigger a backup manually" section referencing
  the Backrest UI + its gRPC CLI (`backrest ... RunPlan`) if that's
  useful for operators.
- No metrics/Grafana dashboard planned for Phase A — ntfy topic is the
  operational surface. Revisit if noise management becomes a problem.
- **Rollback caveats:**
  - **Units 2, 3a, 3b:** Revert the unit's commit; the old
    rustic/restic systemd units re-appear. Repos unchanged. Safe.
  - **Unit 4:** Safe *only before* the first Backrest-authored
    prune cycle runs on any of storage's five repos. The execution
    note requires manual triggers with schedules paused, which keeps
    us inside the safe window. Once schedules are re-enabled and
    one cycle has run, Backrest's retention semantics have begun
    reshaping the snapshot graph — those deletions are unrecoverable,
    and a revert to rustic cannot un-delete them.
  - **Unit 5:** Deletion of `modules/rustic.nix` and
    `modules/constellation/backup.nix` is a coordinated revert
    (each of the four migrated hosts would need a matching revert
    of its Unit 2/3/4 commit). Considered deliberately: Unit 5
    lands only after one full prune cycle + one forced-failure
    drill has succeeded on every host. Until then, the old modules
    stay in the repo as a fallback.

## Sources & References

- **Origin document:** [docs/brainstorms/2026-04-20-unify-backups-backrest-brainstorm.md](../brainstorms/2026-04-20-unify-backups-backrest-brainstorm.md)
- Related code:
  - `modules/rustic.nix`
  - `modules/constellation/backup.nix`
  - `hosts/storage/backup/backup-restic.nix`
  - `hosts/basestar/backup.nix`
  - `hosts/pegasus/backup/backup-server.nix`
  - `hosts/storage/services/ntfy.nix`
  - `modules/media/gateway.nix`
- Related plans:
  - [docs/plans/2026-04-15-feat-secure-local-ntfy-plan.md](2026-04-15-feat-secure-local-ntfy-plan.md) — ntfy publisher credential
  - [docs/plans/2026-04-15-feat-cottage-restic-rest-server-data-pool-plan.md](2026-04-15-feat-cottage-restic-rest-server-data-pool-plan.md) — pegasus (ex-cottage) as second REST target
- External docs:
  - Backrest: https://github.com/garethgeorge/backrest
  - Config proto: https://github.com/garethgeorge/backrest/blob/main/proto/v1/config.proto
  - Hooks: https://garethgeorge.github.io/backrest/docs/hooks
  - Shoutrrr ntfy: https://containrrr.dev/shoutrrr/v0.8/services/ntfy/
