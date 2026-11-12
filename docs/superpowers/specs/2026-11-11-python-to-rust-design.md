# Python to Rust: the deployed tools

Date: 2026-11-11

## Goal

The standing preference for scripts is Rust first, Python second, shell last. This
spec moves the Python **we wrote and still run** to Rust, as typed, tested,
single-binary packages like `pia`, `plab` and `cylon-bot-bridge`. Python that
exists because something external demands it stays Python. Python that nothing
runs any more is deleted (git history is the archive).

Success: the five tools below run from Rust binaries on their hosts, each with
its tests running in its package build. Their Python, and the Python flake checks
that tested it, are gone. Nothing they do that someone relies on has changed.

## Scope

### Rewritten in Rust

| Tool | Host | Today |
|---|---|---|
| `nzxt-fan-control` | raider | `modules/hosts/raider/fan-control/fan_control.py`, long-running root daemon |
| `send-email-event` | every host (`base`) | `packages/send-email-event/send-email.py`; boot/shutdown/weekly mail and the `email@%n` failure handler on every unit |
| `backup-summary` | galactica | `packages/backup-summary/backup_summary.py`, weekly timer |
| `immich-pixel-sync` | galactica | `modules/hosts/galactica/services/immich-pixel-sync/sync.py`, hourly timer |
| `tablet-sync` | galactica | Python embedded in `modules/hosts/galactica/services/tablet-sync.nix`, hourly timer |

### Deleted

- `modules/hosts/pegasus/media-sync.nix` (its embedded Python too): configured with `enable = false`.
- `modules/hosts/galactica/scripts/btrfs-convert-to-subvolume.{py,nix}`: a one-off conversion tool that is no longer needed.
- `scripts/check-integrity.py`: a one-off restore check that nothing references.

### Kept in Python, deliberately

- `tuya-local-rehost`: its core is `tinytuya.find_device`, UDP discovery on three
  ports in three wire formats. A port would be mostly protocol work for a timer that
  rarely acts.
- `check-stock`: needs a real Firefox to get past Cloudflare. It works today.
- `telequebec-archiver`: a manual CLI wrapping GraphQL and yt-dlp. It gets one fix
  (below) and stays Python.
- `scripts/verify-takeout-import.py`, `blog/scripts/blog_image_generator.py`,
  `scripts/pantheon-shot.py`, `packages/libfprint-goodix-521d/extract-firmware.py`.
- Python by necessity: the `home-assistant-midea-ir` component and its `check.py`
  (Home Assistant loads Python), the heating tests (they render Home Assistant's
  Jinja), NixOS VM test scripts and `natpmp-server/test-client.py`, stash plugins,
  `cylon-bot-hook/test/stub.py`, and the `python3 -c` one-liner in `planka.nix`.

### Out of scope

Everything that only the **router** host uses: `router-dashboard`,
`client-monitor`, `ntfy-webhook`, `router_ui/vpn-manager`. The router is
decommissioned for now, so its code is neither ported nor deleted.

## Design

### Layout

Each tool is its own crate at `packages/<tool>/`. It has its own `Cargo.toml` and
`Cargo.lock` and a `package.nix` built with `rustPlatform.buildRustPackage`, so the
by-name loader exposes it as `pkgs.<tool>`. `cargo test` runs in `checkPhase` (the
default), so a failing test fails the build of every host that uses the tool.

Host modules stay where they are and reference `pkgs.<tool>`. Code that lives in a
host directory today (`fan-control/`, `immich-pixel-sync/`, the script inside
`tablet-sync.nix`) moves to `packages/`, as `pia` did. The module keeps the unit,
the timer and the options.

### `packages/ops-common`

This is a library crate that tools pull in as a path dependency. It works the way
`cylon-bot-bridge` uses `cylon-bot-proto`: the package's `src` fileset uses
`root = ./..`, lists `../ops-common/{Cargo.toml,src}` and sets
`sourceRoot = "source/<tool>"`. It holds only code that at least two tools use:

- **`cmd`**: runs a program with an optional timeout and returns a typed outcome:
  not found, failed with exit code and stderr, timed out, or success with stdout.
  Every tool shells out (`liquidctl`, `restic`, `psql`, `exiftool`, `ffmpeg`,
  `msmtp`).
- **`mail`**: builds a raw HTML message (From, To, Subject, `Content-Type:
  text/html; charset=utf-8`, `MIME-Version: 1.0`) and pipes it to `msmtp <to>`.
  It makes 8 attempts with `min(2^n, 30)` s backoff and returns an error when they
  run out; the caller exits 1. It always calls `msmtp`, never `msmtpq`, and the
  comment in today's `send-email.py` explaining why moves here.
  Used by `send-email-event` and `backup-summary`.

Nothing else goes in the crate until a second user appears.

### Dependencies

Blocking `std` throughout: none of the five tools needs async. `clap` (derive) for
CLIs, `serde`/`serde_json`, `minijinja` for the two Jinja templates (the template
files stay as they are), and `chrono`/`chrono-tz` only where local-time formatting
is required. No HTTP client is needed by any tool in scope.

### Behaviour rule

Each tool keeps its observable contract: CLI flags and aliases, environment
variables, files and state formats, email subjects, log lines other things match on,
and exit codes. Internals may be simplified. Bugs found during the investigation are
fixed inside the rewrite, and the commit message lists each fix. Inputs nobody uses
are dropped.

## Per-tool notes

### 1. `nzxt-fan-control` (raider)

- **Port as-is.** The curves, EMA time constants, deadband, step sizes, hold
  timer, emergency (raw ≥ 95 °C on 2 ticks → 100 %), sensor failsafe (5 failures →
  70 %), exit duty 50 % on SIGTERM, 2 s tick on the monotonic clock, the 300 s
  status line and the daily ramp summary are all unchanged. The sources are
  `fan_control.py` and `docs/superpowers/specs/2026-09-24-raider-fan-control-design.md`.
- **Rounding.** Python's `round()` rounds halves to even; the port uses the same
  rule so duty targets match.
- **Sensors.** Read from sysfs exactly as today: hwmon `name` →
  `temp*_label` → `temp*_input`. The sysfs root is a constructor parameter so tests
  can use a fake tree.
- **liquidctl.** Called through `ops-common::cmd`: `liquidctl initialize` at
  start (exit 1 if it fails), and `liquidctl set fanN speed D` with a 10 s timeout.
  A failed write leaves the current duty unchanged so the next tick retries.
- **Shutdown.** SIGTERM is handled with `signal-hook`.
- **Tests.** Every case in `test_fan_control.py` is ported.
- **Unit.** `fan-control.nix` sets `ExecStart` to `${pkgs.nzxt-fan-control}/bin/nzxt-fan-control`.
  liquidctl stays on the unit's `path`.

### 2. `send-email-event` (every host)

- **Same CLI.** Positional `event` (default "Unknown Event"), optional positional
  `extra_content`, `--email-from`, `--email-to`, with environment fallbacks
  `EMAIL_FROM`, `EMAIL_TO`, `EMAIL_TEMPLATE`. Callers in `modules/base/email.nix`
  and `modules/base/systemd-email-notify.nix` are unchanged.
- **Stats.** CPU model is read from `/proc/cpuinfo` (`model name`, falling back to
  `lscpu` output) rather than a `shell=True` pipeline. Kernel and OS come from
  `uname(2)` (`rustix` or `nix`), and uptime and MemAvailable from `/proc`.
  Root-filesystem usage comes from `statvfs("/")`. The red-bar threshold stays at
  ≥ 85 %.
- **Template.** `event-notification.html` is rendered with minijinja,
  autoescape off, with the same variables. If rendering fails, the hand-built HTML
  fallback is used.
- **Subject.** `[<host>] <event> <local ISO-8601 timestamp>`, as today.
- **Logging.** It no longer logs the whole email body at INFO. It logs the subject
  and the outcome, because failure mails carry journal excerpts.
- **Package.** The runtime inputs shrink to `msmtp` (figlet, procps, gawk and aha
  are dropped as unused). `EMAIL_TEMPLATE` keeps pointing at the template in the
  store; it is set by a `makeWrapper` in `package.nix`.
- **Why first among the fleet-wide changes:** it removes Python and jinja2 from
  every host's closure.
- **Tests.** Stats parsing from fixture `/proc` text, template rendering (normal,
  extra content, ≥ 85 % bar), and the fallback path.

### 3. `backup-summary` (galactica)

- **Same CLI and defaults.** `--dry-run` (text table), `--stdout` (HTML), `--send`
  (default), `--to/--email-to`, `--from-email/--from/--email-from`, `--template`,
  `--password-file`, `--backrest-url`. Environment fallbacks are as today. The unit
  in `modules/backup/backup-summary.nix` is unchanged apart from the package.
- **Same sources, timeouts and thresholds.**
  - `restic -r rest:http://127.0.0.1:8000/ snapshots --json` (60 s), grouped by
    hostname, with the per-target max ages including raider's laptop rule.
  - `restic -r /mnt/storage/backups/restic` (48 h).
  - pegasus over Tailscale (30 s; an error becomes UNREACHABLE/WARN).
  - rustic profile `ovh` (45 s), with the same `rustic-ovh` lookup and the same
    env-file fallback.
  - `du -sb` of the two repositories, and `statvfs` of `/mnt/storage`.
- **Timestamps.** restic's nanosecond ISO timestamps are parsed with nanoseconds
  kept (no microsecond truncation needed). The timezone abbreviation in the email
  comes from `chrono-tz` for the host's local zone.
- **Template.** `summary-email.html.j2` is rendered by minijinja. It uses
  `loop.index is even` and `"%.1f"|format`. The `even` test is built in. The one
  `"%.1f"|format` expression becomes a registered `fmt1` filter, so the template
  does not depend on minijinja's printf support.
- **Subject and sending.** `[<host>] Backup Summary: <summary> (YYYY-MM-DD)`, sent
  through `ops-common::mail`.
- **Tests.** Every case in `tests/test_collector.py` and `tests/test_template.py`
  is ported. Today these tests run nowhere.

### 4. `immich-pixel-sync` (galactica)

- **Same CLI and environment.** `--dry-run`, `--force`; the ten `IPS_*` variables,
  each required, exported by the `writeShellApplication` wrapper in `default.nix`
  as today (the wrapper stays, now running the Rust binary). Its runtime inputs
  stay `postgresql` (psql), `exiftool` and `coreutils`.
- **Steps unchanged.**
  1. Non-blocking flock; if the lock is held, exit 0.
  2. `psql -X -A -t -q -v ON_ERROR_STOP=1 … -v owner= -v days= -v notbefore=` with
     the SQL on **stdin**, because psql interpolates variables only from stdin or `-f`.
  3. Parse the `json_agg` result.
  4. Build staged names `{ts}_{id[:8]}_{sanitize(stem)}[.MP]{ext.lower()}`.
  5. Apply the shrink and empty guards (bypassed by `--force`).
  6. Clean up `*.part` files.
  7. Plain staging: a reflink copy to tmp, chmod 0640, rename into place.
  8. Motion staging: the exiftool XMP fields, then a big-endian u32 size + `mpvd`
     + video bytes appended. If muxing fails, fall back to a plain copy.
  9. Unlink stale files.
- **Copies.** `cp --reflink=auto --preserve=timestamps` stays a subprocess. It is
  the simplest way to get a reflink with an automatic fallback.
- **Native Postgres client: rejected.** Peer auth over the socket would work, but
  psql is already a dependency and the query is a single JSON value.
- **Exit codes.** 1 on a query failure or a guard abort, otherwise 0.
- **Tests.** Every case in `test_sync.py` is ported (is_motion, staged_name and
  sanitize, the plan_actions guards, the mpvd box, stage_plain inode and mode).

### 5. `tablet-sync` (galactica)

- **Configuration.** Today Nix bakes the settings into the script text. They
  become CLI flags that the unit sets from the existing
  `constellation.tabletSync.*` options: `--media-dir` (repeatable), `--sync-dir`,
  `--quality`, `--preset`. The `ffmpeg` binary comes from the unit's `path`.
- **Behaviour unchanged.**
  - Scan each media dir recursively for `.sync` files.
  - For each video (`.mkv .mp4 .avi .m4v .webm`, sorted), transcode to
    `<sync>/<rel>/<video rel>.mp4` when the destination is missing or older.
  - Try VAAPI first (`/dev/dri/renderD128`, `format=nv12,hwupload,scale_vaapi=w=1280:h=-2`,
    `h264_vaapi -qp Q`), then libx264 (`-crf Q -preset P`). Both use AAC 128k
    stereo and `+faststart`, and write to `.tmp.mp4` before renaming.
  - Remove top-level sync dirs that no longer have a marker (skipping dot dirs).
  - Lock with flock on `.tablet-sync.lock`, and log timestamped lines to stdout
    and `.tablet-sync.log`.
- **Packaging.** `tablet-sync.nix` keeps its options, tmpfiles rule, unit and
  timer, and puts `pkgs.tablet-sync` on `systemPackages` in place of the wrapper
  script. `python3` leaves the unit's `path`.
- **Tests.** Marker discovery and relative paths over a temporary tree,
  `needs_transcode`, destination naming, and cleanup that leaves dot dirs alone.
  The ffmpeg argument lists are built by a pure function and pinned by a test.

### 0. Deletions and the telequebec fix

All of this lands in one commit:
- Delete `media-sync.nix`, `btrfs-convert-to-subvolume.{py,nix}` and
  `scripts/check-integrity.py`.
- In `telequebec-archiver/cli.py`, make `--no-skip-existing` download instead of
  short-circuiting to "ok".
- Drop the unused `beautifulsoup4` from its `package.nix`.

## Cutover

**One tool at a time.** Each tool is one commit (or a short series) containing:
- the new crate, plus `ops-common` changes if the tool needs them;
- the ported tests;
- the module switched to the binary;
- the deletion of that tool's Python and of its Python flake check in
  `modules/flake/checks.nix` (`raider-fan-control-test`, `immich-pixel-sync-test`).
  `tuya-local-rehost-test` and `heating-policy-test` stay.

That host is deployed and checked before the next tool starts. Everything is
committed to master; no branches.

| Order | Change | Deploy | Check |
|---|---|---|---|
| 0 | Deletions + telequebec fix | `just deploy galactica` (pegasus whenever it next deploys) | `nix build` for galactica and pegasus; `telequebec-archiver --dry-run <slug>` |
| 1 | `nzxt-fan-control` + `ops-common::cmd` | `just deploy raider` | Unit active. Journal shows `initialize` and status lines. Duty follows a stress load up and settles back down |
| 2 | `send-email-event` + `ops-common::mail` | `just deploy @tier1` (the rest at their next deploy) | Start a throwaway failing unit on raider; the failure mail arrives with its journal excerpt. Also `send-email-event test` by hand |
| 3 | `backup-summary` | `just deploy galactica` | `backup-summary --dry-run` matches the Python output from before the switch; `--send` delivers the mail |
| 4 | `immich-pixel-sync` | `just deploy galactica` | `immich-pixel-sync --dry-run` plans zero actions against the current staging dir; the next timer run succeeds |
| 5 | `tablet-sync` | `just deploy galactica` | `systemctl start tablet-sync` reports everything as up to date, with no re-transcodes |

For steps 3 and 4, capture the Python output (`--dry-run`) before switching so
there is something to compare against.

## Risks

- **A broken `send-email-event` silences failure mail fleet-wide.** Step 2's check
  exercises the real `email@%n` path before anything else moves. The `msmtp`
  invocation is unchanged.
- **A wrong plan in `immich-pixel-sync` could delete staged files**, which
  Syncthing then propagates to the phone. The shrink guard is ported first and
  covered by the ported tests. The cutover check is a dry run that must plan zero
  actions.
- **A wrong destination name in `tablet-sync`** would trigger mass re-transcoding.
  The naming test and the "everything up to date" check catch it.
- **raider runs nixpkgs-unstable** and the others run stable. The crates pin their
  dependencies in their own `Cargo.lock`, so the only exposure is the Rust toolchain
  version, which both channels carry at well beyond what these crates need.
