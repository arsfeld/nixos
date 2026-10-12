# niks3-hook SQLITE_BUSY: single-connection queue patch

## Problem

During the 2026-10-11 weekly-update (03:05–03:42), raider's `niks3-hook`
auto-upload daemon logged ~760 `Failed to queue paths … database is locked (5)
(SQLITE_BUSY)` errors. `niks3-hook send` always exits 0, so no build failed, but
every path that hit the error was silently dropped from auto-upload — exactly the
local builds auto-upload exists to cache.

This is not basestar. basestar's niks3 keeps its state in Postgres; the only
SQLite in the path is the hook's local queue, `/var/lib/niks3-hook/upload-queue.db`
on raider. The single HTTP 500 seen in the same run was one narinfo GET from
basestar to `cache.arsfeld.dev` (R2, no server of ours), succeeded on retry, and
is out of scope.

## Cause

Upstream issue Mic92/niks3#409 was closed by `6b7d2e7f`, which moved the WAL and
`busy_timeout` pragmas into the DSN. raider runs that version and still fails.
`OpenQueue` leaves `database/sql`'s pool unbounded, so one process holds several
SQLite connections, and the hook server's `Enqueue` races the worker's
`FetchBatch`/`Remove`/`Retry` for SQLite's single write lock. Upstream's
`TestQueueConcurrentWriters` passes because it exercises only concurrent
`Enqueue`, not that mix.

Measured during planning against the pinned source, with a test where 64
writers enqueue while a loop drains via `FetchBatch` → `Remove`/`Retry`: the
unpatched code fails with `inserting path …: database is locked`. Contention at
that fan-in starves some waiters in SQLite's busy handler past the 5 s
`busy_timeout`. At 8 writers it passes, which is why upstream's test does not
catch it.

Only this daemon ever opens the database (`send` talks to it over a socket), and
no queue method calls another while holding a transaction, so capping the pool
at one connection removes the contention: callers queue in `database/sql`
instead of SQLite's busy handler. With `SetMaxOpenConns(1)` the full hook suite
plus the new test passes 3/3. `_txlock=immediate` was also tried and is worse:
it fails 154 enqueues at `begin transaction` and breaks upstream's own
`TestQueueConcurrentWriters`.

## Rejected alternatives

- **Postgres.** Needs a server: on raider, a database for a path buffer; on
  basestar, the queue would fail in the very outages it exists to absorb. The
  hook is SQLite-only, so it would mean carrying a fork of its storage layer.
- **`_txlock=immediate`.** Measured worse; see above.
- **Retry on BUSY in the hook server.** Treats the symptom; the contention is
  self-inflicted.
- **Upstream PR.** Not opened, by policy. The patch is carried locally.

## Design

1. **Patch** `hosts/raider/niks3-hook-single-conn.patch`, a unified diff against
   the niks3 source touching only `hook/queue.go`: `db.SetMaxOpenConns(1)` in
   `OpenQueue`, with a comment. The regression test
   (`TestQueueEnqueueDuringDrain`, 64 writers against a live drain) is not
   carried: the hook package builds from a test-free fileset with
   `doCheck = false`, so a test hunk would not apply and nothing would run it.
   It lives in the implementation plan as the red/green gate.
2. **Wiring** in `hosts/raider/configuration.nix`:
   `services.niks3-auto-upload.package` set to the module's default package with
   the patch appended via `overrideAttrs` (which preserves the `.override` the
   module uses to inject the socket path; `go.mod` is untouched, so `vendorHash`
   holds). The comment states why the patch exists and to delete it once the
   pinned niks3 contains an equivalent fix. If upstream changes `queue.go`, the
   patch fails to apply and the build fails loudly.

## Verification

- **Red:** the new test fails with SQLITE_BUSY against unpatched source (done
  once during planning; the plan repeats it). If it cannot be made to fail, the
  diagnosis is wrong; stop and re-investigate.
- **Green:** `go test ./hook` passes on the patched tree, and the patched
  package builds.
- **Live:** `just test raider`; after the next heavy build,
  `journalctl -u niks3-auto-upload | grep -c SQLITE_BUSY` is 0.

## Out of scope

The R2 500, basestar's niks3 server, and the uncommitted
`hosts/raider/weekly-update.nix` change.
