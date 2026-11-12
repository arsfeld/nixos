# send-email-event in Rust

Date: 2026-11-11

## Goal

The standing preference for scripts is Rust first, Python second, shell last.
`send-email-event` is the Python with the widest reach in the fleet. Every host
gets it from `base` and runs it for:

- boot, shutdown and weekly mail (`modules/base/email.nix`), and
- the `email@%n` handler that `modules/base/systemd-email-notify.nix` attaches as
  `onFailure` to every systemd service.

Every host therefore carries a Python interpreter and jinja2 in its closure just to
send mail. This spec replaces it with a Rust binary. The email that arrives, the
CLI its callers use, and its delivery behaviour all stay the same.

Success:
- `pkgs.send-email-event` is a Rust package whose tests run in its build.
- `send-email.py` is gone.
- Python and jinja2 leave the package's closure.
- A real `email@%n` failure mail and a manual event mail arrive from a deployed
  tier-1 host and look as they did before.

## Scope

**In scope:** `packages/send-email-event/` only.

**Out of scope:**
- The callers (`email.nix`, `systemd-email-notify.nix`), which keep their exact
  invocations.
- The other Python tools, which were surveyed during this brainstorm. Any of them
  is a separate decision with its own spec. This spec does not stage them as later
  phases.

## Contract kept

- **CLI.** Optional positional `event` (default `Unknown Event`), optional
  positional `extra_content` (default empty), `--email-from`, `--email-to`.
- **Environment.** `EMAIL_FROM` (default `admin@rosenfeld.one`) and `EMAIL_TO`
  (default `alex@rosenfeld.one`) apply when the flag is absent. `EMAIL_TEMPLATE`
  overrides the template path.
- **Subject.** `[<hostname>] <event> <now>`, where `<now>` is local time in
  Python `datetime.now().isoformat()` form: `YYYY-MM-DDTHH:MM:SS.ffffff`, with
  the fraction omitted when the microseconds are zero.
- **Message.** Headers `From`, `To`, `Subject`, `Content-Type: text/html;
  charset="utf-8"`, a blank line, then the rendered HTML.
- **Template.** `event-notification.html`, unchanged, with variables `EVENT`,
  `HOSTNAME`, `CURRENT_DATE`, `STATS`, `EXTRA_CONTENT`. **Autoescape stays off.**
  `EXTRA_CONTENT` carries pre-rendered HTML from `aha`, and the template already
  marks it `| safe`.
- **Stats** (`STATS` keys; any missing key hides its tile):
  - `cpu` `{label: "Processor", value}`, `value` defaulting to `Unknown`.
  - `uptime` `{label: "Uptime", value, sub}`:
    - `Nd Nh` / `Nm` when at least a day;
    - `Nh Nm` / `since boot` when at least an hour;
    - otherwise `Nm` / `since boot`.
  - `kernel` `{label: "Kernel", value: release or "?", sub: sysname}`.
  - `memory` `{label: "Memory", value: "U.U / T.T GiB", percent, color}`:
    used = MemTotal − MemAvailable (MemFree if MemAvailable is absent). Omitted
    when MemTotal is 0 or unreadable.
  - `disk` `{label: "Disk /", value: "U / T GiB", percent, color}` from
    `statvfs("/")`: total = `f_blocks·f_frsize`, used = total −
    `f_bavail·f_frsize`. Omitted on error.
  - Percentages are rounded half-to-even, like Python's `round()`. `color` is
    `#ef4444` at ≥ 85 %, otherwise `#4f46e5`.
- **Delivery.** Pipe the message to `msmtp <to>` on stdin, never `msmtpq`. Make
  up to 8 attempts, sleeping `min(2^attempt, 30)` s after failed attempt
  `attempt`. After the last failure, exit 1. The comment in `send-email.py`
  explaining why `msmtpq` is avoided and why the recipient is an argument moves
  over verbatim.
- **Render failure.** If the template fails to load or render, send the plain
  fallback HTML (event, hostname, date, stats, extra content). The mail is never
  dropped.

## Changes, deliberate

- **CPU model.** Read from the first `model name` line of `/proc/cpuinfo` instead
  of the `lscpu | grep | cut` shell pipeline. On a host with no such line (the
  aarch64 ones), fall back to `lscpu` and take its `Model name:` field. If both
  fail, use `Unknown`. Today a failure puts the error text itself into the tile.
- **Kernel.** Taken from `uname(2)` instead of spawning `uname -r`/`uname -s`.
- **Logging.** It no longer logs the whole email at INFO, because failure mails
  carry journal excerpts. It logs one line per attempt and the outcome:
  - `Email sent to <to>`
  - `Send attempt n/8 failed (<stderr>); retrying in Ns`
  - `Giving up after 8 attempts: <stderr>`
- **Header.** Adds `MIME-Version: 1.0`.
- **Runtime inputs.** These shrink to `msmtp`, plus `util-linux` for the `lscpu`
  fallback. `aha` (called by full path in `systemd-email-notify.nix`), `figlet`,
  `procps`, `gawk`, `gnugrep` and `coreutils` are dropped.

## Design

### Layout

```
packages/send-email-event/
  Cargo.toml  Cargo.lock  package.nix
  event-notification.html        (unchanged)
  src/main.rs                    CLI, wiring, exit code
  src/stats.rs                   pure parsers + collection
  src/render.rs                  template + fallback
  src/mail.rs                    message assembly + msmtp retry loop
```

There is no shared crate. This is the only tool being ported, so `mail` and the
command runner live inside this crate.

### Units

- **`stats`.**
  - Pure functions over text and numbers: `parse_uptime(&str)`,
    `parse_meminfo(&str)`, `cpu_model_from_cpuinfo(&str)`,
    `cpu_model_from_lscpu(&str)`, `format_uptime(f64)`, `round_half_even(f64)`,
    `bar_color(u32)`, and `disk_stat(blocks, bavail, frsize)`.
  - `collect()` reads `/proc` and calls `statvfs` and `uname` through `rustix`,
    returning a `Stats` struct. Its fields are `Option`s that serialize to the
    template's map, with absent fields left out.
- **`render`.**
  - `render(template_src, ctx) -> Result<String>` uses `minijinja`, with
    autoescape disabled for every file name, and runs the template's macros,
    `| safe`, and `100 - s.percent` as they are.
  - `fallback(ctx) -> String` builds the plain fallback HTML.
- **`mail`.**
  - `message(from, to, subject, html) -> String` assembles the message.
  - `send(to, message, runner, sleeper)` runs the retry loop. The command runner
    and the sleep are injected so tests run instantly and can script failures.
- **`main`.**
  - Parses arguments with `clap` (derive).
  - Resolves from/to/template from flags, then the environment, then the defaults.
  - Uses the template from `EMAIL_TEMPLATE` when set. Otherwise it uses the copy
    compiled in with `include_str!`, so the binary works with no wrapper.
  - Takes the hostname from `uname` nodename (what `socket.gethostname()`
    returns) and the time from `chrono::Local`.

### Dependencies

`clap`, `minijinja`, `serde`, `chrono`, `rustix` (features `fs`, `system`).
Blocking only, with no async runtime and no HTTP client.

### Packaging

`package.nix` uses `rustPlatform.buildRustPackage`:
- Its `src` fileset is `Cargo.toml`, `Cargo.lock`, `src`, `event-notification.html`.
- `cargo test` runs in `checkPhase`, so a failing test fails every host build.
- `makeWrapper`'s `wrapProgram` prefixes PATH with `msmtp` and `util-linux` and
  sets `EMAIL_TEMPLATE` to the store copy of the template. The callers run inside
  systemd units with a minimal PATH, which is why the wrapper supplies `msmtp`.
- `meta.mainProgram = "send-email-event"`.

The package is used through `pkgs.send-email-event` by both callers. The by-name
loader picks it up as before, so no caller changes.

## Testing

Unit tests, all in-crate:
- `/proc` parsers against fixture text: x86 `cpuinfo`, aarch64 `cpuinfo` with no
  model name plus `lscpu` output, `meminfo` with and without MemAvailable, and
  `uptime`.
- `format_uptime` at 59 s, 1 h, 1 d, and 3 d 4 h.
- `round_half_even` (0.5 → 0, 1.5 → 2, 84.5 → 84, 85.5 → 86) and the 85 % colour
  threshold.
- Rendering the real `event-notification.html`:
  - all stats present;
  - memory and disk absent (tiles hidden);
  - extra content containing HTML is passed through unescaped;
  - an event with `<` is not escaped, matching today.
- A broken template falls back to the plain HTML.
- `send`:
  - success on the first try (one call, no sleep);
  - success on the 3rd (sleeps of 2 s and 4 s);
  - 8 failures (sleeps 2, 4, 8, 16, 30, 30, 30, then `Err`);
  - the recipient is passed as an argument and the message as stdin.
- `datetime` formatting with and without microseconds.

Before switching, render one mail with the Python version and one with the Rust
version from the same fixed inputs, and diff the HTML by hand. This is a one-time
check, not a kept test.

## Rollout

1. One commit: the new crate, the new `package.nix`, and `send-email.py` deleted.
2. `nix build .#nixosConfigurations.raider.config.system.build.toplevel`, which
   runs the crate's tests through the package build.
3. `nix develop -c just deploy @tier1`. Other hosts pick it up at their next
   deploy; the CLI is unchanged, so mixed versions are harmless.
4. On raider:
   - Run `send-email-event "test event"` and confirm the mail arrives.
   - Start a throwaway unit that exits 1 (`systemd-run --unit=email-test false`).
     Confirm the `email@` failure mail arrives with its status and log sections
     rendered.
   - Check on galactica that `journalctl -u email@…` shows the new log lines.

## Risks

- **A broken binary silences failure mail on every host it reaches.** Mitigations:
  - The retry loop and `msmtp` invocation are pinned by tests.
  - Rollout step 4 exercises the real `email@%n` path on tier 1 before any other
    host deploys.
  - The render fallback means a template problem still delivers mail.
- **minijinja differs from Jinja2** in some edge cases (undefined attributes,
  macros). The template uses only attribute tests, macros, `| safe`, `if` and
  integer subtraction. All of them are covered by the render tests over the real
  template, and the one-time Python-versus-Rust diff checks the output.
